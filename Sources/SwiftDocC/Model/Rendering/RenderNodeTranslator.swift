/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Foundation
import Markdown
import SymbolKit

/// A visitor which converts a semantic model into a render node.
///
/// The translator visits the contents of a ``DocumentationNode``'s ``Semantic`` model and creates a ``RenderNode``.
/// The translation is lossy, meaning that translating a ``RenderNode`` back to a ``Semantic`` is not possible with full fidelity.
/// For example, source markup syntax is not preserved during the translation.
public struct RenderNodeTranslator: SemanticVisitor {

    /// Resolved topic references that were seen by the visitor. These should be used to populate the references dictionary.
    var collectedTopicReferences: [ResolvedTopicReference] = []
    
    /// Unresolvable topic references outside the current bundle.
    var collectedUnresolvedTopicReferences: [UnresolvedTopicReference] = []
    
    /// Any collected constraints to symbol relationships.
    var collectedConstraints: [TopicReference: [SymbolGraph.Symbol.Swift.GenericConstraint]] = [:]
    
    /// A context containing pre-rendered content.
    let renderContext: RenderContext?
    
    /// A collection of functions that render pieces of documentation content.
    let contentRenderer: DocumentationContentRenderer
    
    /// Whether the documentation converter should include source file
    /// location metadata in any render nodes representing symbols it creates.
    ///
    /// Before setting this value to `true` please confirm that your use case doesn't
    /// include public distribution of any created render nodes as there are filesystem privacy and security
    /// concerns with distributing this data.
    let shouldEmitSymbolSourceFileURIs: Bool
    
    /// Whether the documentation converter should include access level information for symbols.
    let shouldEmitSymbolAccessLevels: Bool
    
    public mutating func visitCode(_ code: Code) -> RenderTree? {
        let fileType = NSString(string: code.fileName).pathExtension
        let fileReference = code.fileReference
        
        guard let fileData = try? context.resource(with: code.fileReference),
            let fileContents = String(data: fileData, encoding: .utf8) else {
            return RenderReferenceIdentifier("")
        }
        
        let assetReference = RenderReferenceIdentifier(fileReference.path)
        
        fileReferences[fileReference.path] = FileReference(
            identifier: assetReference,
            fileName: code.fileName,
            fileType: fileType,
            syntax: fileType,
            content: fileContents.splitByNewlines
        )
        return assetReference
    }
    
    public mutating func visitSteps(_ steps: Steps) -> RenderTree? {
        let stepsContent = steps.content.flatMap { child -> [RenderBlockContent] in
            return visit(child) as! [RenderBlockContent]
        }
        
        return stepsContent
    }
    
    public mutating func visitStep(_ step: Step) -> RenderTree? {
        let renderBlock = visitMarkupContainer(MarkupContainer(step.content)) as! [RenderBlockContent]
        let caption = visitMarkupContainer(MarkupContainer(step.caption)) as! [RenderBlockContent]
        
        let mediaReference = step.media.map { visit($0) } as? RenderReferenceIdentifier
        let codeReference = step.code.map { visitCode($0) } as? RenderReferenceIdentifier
        
        let previewReference = step.code?.preview.map {
            createAndRegisterRenderReference(forMedia: $0.source, altText: ($0 as? ImageMedia)?.altText)
        }
        
        let result = [RenderBlockContent.step(content: renderBlock, caption: caption, media: mediaReference, code: codeReference, runtimePreview: previewReference)]
        
        return result
    }
    
    public mutating func visitTutorialSection(_ tutorialSection: TutorialSection) -> RenderTree? {
        let introduction = contentLayouts(tutorialSection.introduction)
        let stepsContent: [RenderBlockContent]
        if let steps = tutorialSection.stepsContent {
            stepsContent = visit(steps) as! [RenderBlockContent]
        } else {
            stepsContent = []
        }
        
        let highlightsPerFile = LineHighlighter(context: context, tutorialSection: tutorialSection).highlights
        
        // Add the highlights to the file references.
        for result in highlightsPerFile {
            fileReferences[result.file.path]?.highlights = result.highlights
        }
        
        return TutorialSectionsRenderSection.Section(title: tutorialSection.title, contentSection: introduction, stepsSection: stepsContent, anchor: urlReadableFragment(tutorialSection.title))
    }
    
    public mutating func visitTutorial(_ tutorial: Tutorial) -> RenderTree? {
        var node = RenderNode(identifier: identifier, kind: .tutorial)
        
        var hierarchyTranslator = RenderHierarchyTranslator(context: context, bundle: bundle)
        guard let hierarchy = hierarchyTranslator.visitTechnologyNode(identifier) else {
            // This tutorial is not curated, so we don't generate a render node.
            // We've warned about this during semantic analysis.
            return nil
        }
        
        let technology = try! context.entity(with: hierarchy.technology).semantic as! Technology
        
        node.metadata.title = tutorial.intro.title
        node.metadata.role = contentRenderer.role(for: .tutorial).rawValue
        
        collectedTopicReferences.append(contentsOf: hierarchyTranslator.collectedTopicReferences)
        
        node.hierarchy = hierarchy.hierarchy
        node.metadata.category = technology.name
        
        node.metadata.categoryPathComponent = hierarchy.technology.url.lastPathComponent
                
        var intro = visitIntro(tutorial.intro) as! IntroRenderSection
        intro.estimatedTimeInMinutes = tutorial.durationMinutes
        
        if let chapterReference = context.parents(of: identifier).first {
            intro.chapter = context.title(for: chapterReference)
        }
        // Add an Xcode requirement to the tutorial intro if one is provided.
        if let requirement = tutorial.requirements.first {
            let identifier = RenderReferenceIdentifier(requirement.title)
            let requirementReference = XcodeRequirementReference(identifier: identifier, title: requirement.title, url: requirement.destination)
            requirementReferences[identifier.identifier] = requirementReference 
            intro.xcodeRequirement = identifier
        }
        
        if let projectFiles = tutorial.projectFiles {
            intro.projectFiles = createAndRegisterRenderReference(forMedia: projectFiles, assetContext: .download)
        }
        
        node.sections.append(intro)
        
        var tutorialSections = TutorialSectionsRenderSection(sections: tutorial.sections.map { visitTutorialSection($0) as! TutorialSectionsRenderSection.Section })

        // Attach anchors to tutorial sections.
        // Find the reference associated with the section, by searching the tutorial's children for a node that has a matching title.
        // This assumes that the rendered `tasks` are in the same order as `tutorial.sections`.
        let sectionReferences = context.children(of: identifier, kind: .onPageLandmark)
        tutorialSections.tasks = tutorialSections.tasks.enumerated().map { (index, section) in
            var section = section
            section.anchor = sectionReferences[index].reference.fragment ?? ""
            return section
        }
        
        node.sections.append(tutorialSections)
        if let assesments = tutorial.assessments {
            node.sections.append(visitAssessments(assesments) as! TutorialAssessmentsRenderSection)
        }

        // We guarantee there will be at least 1 path with at least 4 nodes in that path if the tutorial is curated.
        // The way to curate tutorials is to link them from a Technology page and that generates the following hierarchy:
        // technology -> volume -> chapter -> tutorial.
        let technologyPath = context.pathsTo(identifier, options: [.preferTechnologyRoot])[0]
        
        if technologyPath.count >= 2 {
            let volume = technologyPath[technologyPath.count - 2]
            
            if let cta = callToAction(with: tutorial.callToActionImage, volume: volume) {
                node.sections.append(cta)
            }
        }
        
        node.references = createTopicRenderReferences()

        addReferences(fileReferences, to: &node)
        addReferences(imageReferences, to: &node)
        addReferences(videoReferences, to: &node)
        addReferences(requirementReferences, to: &node)
        addReferences(downloadReferences, to: &node)
        addReferences(linkReferences, to: &node)
        addReferences(hierarchyTranslator.linkReferences, to: &node)
        return node
    }
    
    /// Creates a CTA for tutorials and tutorial articles.
    private mutating func callToAction(with callToActionImage: ImageMedia?, volume: ResolvedTopicReference) -> CallToActionSection? {
        // Get all the tutorials and tutorial articles in the learning path, ordered.

        var surroundingTopics = [(reference: ResolvedTopicReference, kind: DocumentationNode.Kind)]()
        context.traverseBreadthFirst(from: volume) { node in
            if node.kind == .tutorial || node.kind == .tutorialArticle {
                surroundingTopics.append((node.reference, node.kind))
            }
            return .continue
        }
        
        // Find the tutorial or article that comes after the current page, if one exists.
        let nextTopicIndex = surroundingTopics.firstIndex(where: { $0.reference == identifier }).map { $0 + 1 }
        if let nextTopicIndex = nextTopicIndex, nextTopicIndex < surroundingTopics.count {
            let nextTopicReference = surroundingTopics[nextTopicIndex]
            let nextTopicReferenceIdentifier = visitResolvedTopicReference(nextTopicReference.reference) as! RenderReferenceIdentifier
            let nextTopic = try! context.entity(with: nextTopicReference.reference).semantic as! Abstracted & Titled
            
            let image = callToActionImage.map { visit($0) as! RenderReferenceIdentifier }
            
            return createCallToAction(reference: nextTopicReferenceIdentifier, kind: nextTopicReference.kind, title: nextTopic.title ?? "", abstract: inlineAbstractContentInTopic(nextTopic), image: image)
        }
        
        return nil
    }
    
    private mutating func createCallToAction(reference: RenderReferenceIdentifier, kind: DocumentationNode.Kind, title: String, abstract: [RenderInlineContent], image: RenderReferenceIdentifier?) -> CallToActionSection {
        let overridingTitle: String
        let eyebrow: String
        switch kind {
        case .tutorial:
            overridingTitle = "Get started"
            eyebrow = "Tutorial"
        case .tutorialArticle:
            overridingTitle = "Read article"
            eyebrow = "Article"
        default:
            fatalError("Unexpected kind '\(kind)', only tutorials and tutorial articles may be CTA destinations.")
        }
        
        let action = RenderInlineContent.reference(identifier: reference, isActive: true, overridingTitle: overridingTitle, overridingTitleInlineContent: [.text(overridingTitle)])
        return CallToActionSection(title: title, abstract: abstract, media: image, action: action, featuredEyebrow: eyebrow)
    }
    
    private mutating func inlineAbstractContentInTopic(_ topic: Abstracted) -> [RenderInlineContent] {
        if let abstract = topic.abstract {
            return (visitMarkupContainer(MarkupContainer(abstract)) as! [RenderBlockContent]).firstParagraph
        }
        
        return []
    }
    
    public mutating func visitIntro(_ intro: Intro) -> RenderTree? {
        var section = IntroRenderSection(title: intro.title)
        section.content = visitMarkupContainer(intro.content) as! [RenderBlockContent]
        
        section.image = intro.image.map { visit($0) } as? RenderReferenceIdentifier
        section.video = intro.video.map { visit($0) } as? RenderReferenceIdentifier
        
        // Set the Intro's background image to the video's poster image.
        section.backgroundImage = intro.video?.poster.map { createAndRegisterRenderReference(forMedia: $0) }
            ?? intro.image.map { createAndRegisterRenderReference(forMedia: $0.source) }
        
        return section
    }
    
    /// Add a requirement reference and return its identifier.
    public mutating func visitXcodeRequirement(_ requirement: XcodeRequirement) -> RenderTree? {
        fatalError("TODO")
    }
    
    public mutating func visitAssessments(_ assessments: Assessments) -> RenderTree? {
        let renderSectionAssessments: [TutorialAssessmentsRenderSection.Assessment] = assessments.questions.map { question in
            return self.visitMultipleChoice(question) as! TutorialAssessmentsRenderSection.Assessment
        }
        
        return TutorialAssessmentsRenderSection(assessments: renderSectionAssessments, anchor: RenderHierarchyTranslator.assessmentsAnchor)
    }
    
    public mutating func visitMultipleChoice(_ multipleChoice: MultipleChoice) -> RenderTree? {
        let questionPhrasing = visit(multipleChoice.questionPhrasing) as! [RenderBlockContent]
        let content = visitMarkupContainer(multipleChoice.content) as! [RenderBlockContent]
        return TutorialAssessmentsRenderSection.Assessment(title: questionPhrasing, content: content, choices: multipleChoice.choices.map { visitChoice($0) } as! [TutorialAssessmentsRenderSection.Assessment.Choice])
    }
    
    public mutating func visitChoice(_ choice: Choice) -> RenderTree? {
        return TutorialAssessmentsRenderSection.Assessment.Choice(
            content: visitMarkupContainer(choice.content) as! [RenderBlockContent],
            isCorrect: choice.isCorrect,
            justification: (visitJustification(choice.justification) as! [RenderBlockContent]),
            reaction: choice.justification.reaction
        )
    }
    
    public mutating func visitJustification(_ justification: Justification) -> RenderTree? {
        return visitMarkupContainer(justification.content) as! [RenderBlockContent]
    }
        
    // Visits a container and expects the elements to be block level elements
    public mutating func visitMarkupContainer(_ markupContainer: MarkupContainer) -> RenderTree? {
        var contentCompiler = RenderContentCompiler(context: context, bundle: bundle, identifier: identifier)
        let content = markupContainer.elements.reduce(into: [], { result, item in result.append(contentsOf: contentCompiler.visit(item))}) as! [RenderBlockContent]
        collectedTopicReferences.append(contentsOf: contentCompiler.collectedTopicReferences)
        // Copy all the image references found in the markup container.
        imageReferences.merge(contentCompiler.imageReferences) { (_, new) in new }
        linkReferences.merge(contentCompiler.linkReferences) { (_, new) in new }
        return content
    }
    
    // Visits a collection of inline markup elements.
    public mutating func visitMarkup(_ markup: [Markup]) -> RenderTree? {
        var contentCompiler = RenderContentCompiler(context: context, bundle: bundle, identifier: identifier)
        let content = markup.reduce(into: [], { result, item in result.append(contentsOf: contentCompiler.visit(item))}) as! [RenderInlineContent]
        collectedTopicReferences.append(contentsOf: contentCompiler.collectedTopicReferences)
        // Copy all the image references.
        imageReferences.merge(contentCompiler.imageReferences) { (_, new) in new }
        return content
    }

    // Visits a single inline markup element.
    public mutating func visitMarkup(_ markup: Markup) -> RenderTree? {
        return visitMarkup(Array(markup.children))
    }
    
    private func firstTutorial(ofTechnology technology: ResolvedTopicReference) -> (reference: ResolvedTopicReference, kind: DocumentationNode.Kind)? {
        guard let volume = (context.children(of: technology, kind: .volume)).first,
            let firstChapter = (context.children(of: volume.reference)).first,
            let firstTutorial = (context.children(of: firstChapter.reference)).first else
        {
            return nil
        }
        return firstTutorial
    }

    /// Returns a description of the total estimated duration to complete the tutorials of the given technology.
    /// - Returns: The estimated duration, or `nil` if there are no tutorials with time estimates.
    private func totalEstimatedDuration(for technology: Technology) -> String? {
        var totalDurationMinutes: Int? = nil

        context.traverseBreadthFirst(from: identifier) { node in
            if let entity = try? context.entity(with: node.reference),
                let durationMinutes = (entity.semantic as? Timed)?.durationMinutes
            {
                if totalDurationMinutes == nil {
                    totalDurationMinutes = 0
                }
                totalDurationMinutes! += durationMinutes
            }

            return .continue
        }


        return totalDurationMinutes.flatMap(contentRenderer.formatEstimatedDuration(minutes:))
    }

    public mutating func visitTechnology(_ technology: Technology) -> RenderTree? {
        var node = RenderNode(identifier: identifier, kind: .overview)
        
        node.metadata.title = technology.intro.title
        node.metadata.category = technology.name
        node.metadata.categoryPathComponent = identifier.url.lastPathComponent
        node.metadata.estimatedTime = totalEstimatedDuration(for: technology)
        node.metadata.role = contentRenderer.role(for: .technology).rawValue

        var intro = visitIntro(technology.intro) as! IntroRenderSection
        if let firstTutorial = self.firstTutorial(ofTechnology: identifier) {
            intro.action = visitLink(firstTutorial.reference.url, defaultTitle: "Get started")
        }
        node.sections.append(intro)
                
        node.sections.append(contentsOf: technology.volumes.map { visitVolume($0) as! VolumeRenderSection })
        
        if let resources = technology.resources {
            node.sections.append(visitResources(resources) as! ResourcesRenderSection)
        }
        
        var hierarchyTranslator = RenderHierarchyTranslator(context: context, bundle: bundle)
        node.hierarchy = hierarchyTranslator
            .visitTechnologyNode(identifier, omittingChapters: true)!
            .hierarchy

        collectedTopicReferences.append(contentsOf: hierarchyTranslator.collectedTopicReferences)
        
        node.references = createTopicRenderReferences()
        
        addReferences(fileReferences, to: &node)
        addReferences(imageReferences, to: &node)
        addReferences(videoReferences, to: &node)
        addReferences(linkReferences, to: &node)
        
        return node
    }
    
    private mutating func createTopicRenderReferences() -> [String: RenderReference] {
        var renderReferences: [String: RenderReference] = [:]
        let renderer = DocumentationContentRenderer(documentationContext: context, bundle: bundle)
        
        for reference in collectedTopicReferences {
            var renderReference: TopicRenderReference
            var dependencies: RenderReferenceDependencies
            
            if let renderContext = renderContext, let prerendered = renderContext.store.content(for: reference)?.renderReference as? TopicRenderReference,
                let renderReferenceDependencies = renderContext.store.content(for: reference)?.renderReferenceDependencies {
                renderReference = prerendered
                dependencies = renderReferenceDependencies
            } else {
                dependencies = RenderReferenceDependencies()
                renderReference = renderer.renderReference(for: reference, dependencies: &dependencies)
            }
            
            for link in dependencies.linkReferences {
                linkReferences[link.identifier.identifier] = link
            }
            
            for dependencyReference in dependencies.topicReferences {
                var dependencyRenderReference: TopicRenderReference
                if let renderContext = renderContext, let prerendered = renderContext.store.content(for: dependencyReference)?.renderReference as? TopicRenderReference {
                    dependencyRenderReference = prerendered
                } else {
                    var dependencies = RenderReferenceDependencies()
                    dependencyRenderReference = renderer.renderReference(for: dependencyReference, dependencies: &dependencies)
                }
                renderReferences[dependencyReference.absoluteString] = dependencyRenderReference
            }
            
            // Add any conformance constraints to the reference, if any are present.
            if let conformanceSection = renderer.conformanceSectionFor(reference, collectedConstraints: collectedConstraints) {
                renderReference.conformance = conformanceSection
            }
            
            renderReferences[reference.absoluteString] = renderReference
        }

        for unresolved in collectedUnresolvedTopicReferences {
            let renderReference = UnresolvedRenderReference(
                identifier: RenderReferenceIdentifier(unresolved.topicURL.absoluteString),
                title: unresolved.title ?? unresolved.topicURL.absoluteString
            )
            renderReferences[renderReference.identifier.identifier] = renderReference
        }
        
        return renderReferences
    }
    
    private func addReferences<Reference>(_ references: [String: Reference], to node: inout RenderNode) where Reference: RenderReference {
        node.references.merge(references) { _, new in new }
    }

    public mutating func visitVolume(_ volume: Volume) -> RenderTree? {
        var volumeSection = VolumeRenderSection(name: volume.name)
        volumeSection.image = volume.image.map { visit($0) as! RenderReferenceIdentifier }
        volumeSection.content = volume.content.map { visitMarkupContainer($0) as! [RenderBlockContent] }
        volumeSection.chapters = volume.chapters.compactMap { visitChapter($0) } as? [VolumeRenderSection.Chapter] ?? []
        return volumeSection
    }
    
    public mutating func visitImageMedia(_ imageMedia: ImageMedia) -> RenderTree? {
        return createAndRegisterRenderReference(forMedia: imageMedia.source, altText: imageMedia.altText)
    }
    
    public mutating func visitVideoMedia(_ videoMedia: VideoMedia) -> RenderTree? {
        return createAndRegisterRenderReference(forMedia: videoMedia.source, poster: videoMedia.poster)
    }
    
    public mutating func visitChapter(_ chapter: Chapter) -> RenderTree? {
        guard !chapter.topicReferences.isEmpty else {
            // If the chapter has no tutorials, return `nil`.
            return nil
        }
        
        var renderChapter = VolumeRenderSection.Chapter(name: chapter.name)
        renderChapter.content = visitMarkupContainer(chapter.content) as! [RenderBlockContent]
        renderChapter.tutorials = chapter.topicReferences.map { visitTutorialReference($0) } as! [RenderReferenceIdentifier]
        renderChapter.image = chapter.image.map { visit($0) } as? RenderReferenceIdentifier
        
        return renderChapter
    }
    
    public mutating func visitContentAndMedia(_ contentAndMedia: ContentAndMedia) -> RenderTree? {
        var layout: ContentAndMediaSection.Layout? {
            switch contentAndMedia.layout {
            case .horizontal: return .horizontal
            case .vertical: return .vertical
            case nil: return nil
            }
        }

        let mediaReference = contentAndMedia.media.map { visit($0) } as? RenderReferenceIdentifier
        var section = ContentAndMediaSection(layout: layout, title: contentAndMedia.title, media: mediaReference, mediaPosition: contentAndMedia.mediaPosition)
        
        section.eyebrow = contentAndMedia.eyebrow
        section.content = visitMarkupContainer(contentAndMedia.content) as! [RenderBlockContent]
        
        return section
    }
        
    public mutating func visitTutorialReference(_ tutorialReference: TutorialReference) -> RenderTree? {
        switch context.resolve(tutorialReference.topic, in: bundle.rootReference) {
        case let .unresolved(reference):
            return RenderReferenceIdentifier(reference.topicURL.absoluteString)
        case let .resolved(resolved):
            return visitResolvedTopicReference(resolved)
        }
    }
    
    public mutating func visitResolvedTopicReference(_ resolvedTopicReference: ResolvedTopicReference) -> RenderTree {
        collectedTopicReferences.append(resolvedTopicReference)
        return RenderReferenceIdentifier(resolvedTopicReference.absoluteString)
    }
        
    public mutating func visitResources(_ resources: Resources) -> RenderTree? {
        let tiles = resources.tiles.map { visitTile($0) as! RenderTile }
        let content = visitMarkupContainer(resources.content) as! [RenderBlockContent]
        return ResourcesRenderSection(tiles: tiles, content: content)
    }

    public mutating func visitLink(_ link: URL, defaultTitle overridingTitle: String?) -> RenderInlineContent {
        let overridingTitleInlineContent: [RenderInlineContent]? = overridingTitle.map { [RenderInlineContent.text($0)] }
        
        let action: RenderInlineContent
        // We expect, at this point of the rendering, this API to be called with valid URLs, otherwise crash.
        let unresolved = UnresolvedTopicReference(topicURL: ValidatedURL(link)!)
        if case let .resolved(resolved) = context.resolve(.unresolved(unresolved), in: bundle.rootReference) {
            action = RenderInlineContent.reference(identifier: RenderReferenceIdentifier(resolved.absoluteString),
                                                   isActive: true,
                                                   overridingTitle: overridingTitle,
                                                   overridingTitleInlineContent: overridingTitleInlineContent)
            collectedTopicReferences.append(resolved)
        } else if !ResolvedTopicReference.urlHasResolvedTopicScheme(link) {
            // This is an external link
            let externalLinkIdentifier = RenderReferenceIdentifier(forExternalLink: link.absoluteString)
            if linkReferences.keys.contains(externalLinkIdentifier.identifier) {
                // If we've already seen this link, return the existing reference with an overriden title.
                action = RenderInlineContent.reference(identifier: externalLinkIdentifier,
                                                       isActive: true,
                                                       overridingTitle: overridingTitle,
                                                       overridingTitleInlineContent: overridingTitleInlineContent)
            } else {
                // Otherwise, create and save a new link reference.
                let linkReference = LinkReference(identifier: externalLinkIdentifier,
                                                  title: overridingTitle ?? link.absoluteString,
                                                  titleInlineContent: overridingTitleInlineContent ?? [.text(link.absoluteString)],
                                                  url: link.absoluteString)
                linkReferences[externalLinkIdentifier.identifier] = linkReference
                
                action = RenderInlineContent.reference(identifier: externalLinkIdentifier, isActive: true, overridingTitle: nil, overridingTitleInlineContent: nil)
            }
        } else {
            // This is an unresolved doc: URL. We render the link inactive by converting it to plain text,
            // as it may break routing or other downstream uses of the URL.
            action = RenderInlineContent.text(link.path)
        }
        
        return action
    }
    
    public mutating func visitTile(_ tile: Tile) -> RenderTree? {
        let action = tile.destination.map { visitLink($0, defaultTitle: RenderTile.defaultCallToActionTitle(for: tile.identifier)) }
        
        var section = RenderTile(identifier: .init(tileIdentifier: tile.identifier), title: tile.title, action: action, media: nil)
        section.content = visitMarkupContainer(tile.content) as! [RenderBlockContent]
        
        return section
    }
    
    public mutating func visitArticle(_ article: Article) -> RenderTree? {
        var node = RenderNode(identifier: identifier, kind: .article)
        var contentCompiler = RenderContentCompiler(context: context, bundle: bundle, identifier: identifier)
        
        node.metadata.title = article.title!.plainText
        
        // Detect the article modules from its breadcrumbs.
        let modules = context.pathsTo(identifier).compactMap({ path -> String? in
            return path.mapFirst(where: { ancestor in
                guard let ancestorNode = try? context.entity(with: ancestor) else { return nil }
                return (ancestorNode.semantic as? Symbol)?.moduleName
            })
        })
        if !modules.isEmpty {
            node.metadata.modules = Array(Set(modules)).map({
                return RenderMetadata.Module(name: $0, relatedModules: nil)
            })
        }
        
        let documentationNode = try! context.entity(with: identifier)
        
        var hierarchyTranslator = RenderHierarchyTranslator(context: context, bundle: bundle)
        let hierarchy = hierarchyTranslator.visitArticle(identifier)
        collectedTopicReferences.append(contentsOf: hierarchyTranslator.collectedTopicReferences)
        node.hierarchy = hierarchy
        
        // Find the language of the symbol that curated the article in the graph
        // and use it as the interface language for that article.
        if let language = try! context.interfaceLanguageFor(identifier)?.id {
            let generator = PresentationURLGenerator(context: context, baseURL: bundle.baseURL)
            node.variants = [
                .init(traits: [.interfaceLanguage(language)], paths: [
                    generator.presentationURLForReference(identifier).path
                ])
            ]
        }
        
        if let abstract = article.abstractSection,
            let abstractContent = visitMarkup(abstract.content) as? [RenderInlineContent] {
            node.abstract = abstractContent
        } else {
            node.abstract = [.text("No overview available.")]
        }
        
        if let discussion = article.discussion,
            let discussionContent = visitMarkupContainer(MarkupContainer(discussion.content)) as? [RenderBlockContent] {
            var title: String?
            if let first = discussionContent.first, case RenderBlockContent.heading = first {
                title = nil
            } else {
                // For articles hardcode an overview title
                title = "Overview"
            }
            node.primaryContentSections.append(ContentRenderSection(kind: .content, content: discussionContent, heading: title))
        }
        
        if let topics = article.topics, !topics.taskGroups.isEmpty {
            // Don't set an eyebrow as collections and groups don't have one; append the authored Topics section
            node.topicSections.append(contentsOf: renderGroups(topics, allowExternalLinks: false, contentCompiler: &contentCompiler))
        }
        
        // Place "top" rendering preference automatic task groups
        // after any user-defined task gruops but before automatic curation.
        if !article.automaticTaskGroups.isEmpty {
            node.topicSections.append(contentsOf: renderAutomaticTaskGroupsSection(article.automaticTaskGroups.filter({ $0.renderPositionPreference == .top }), contentCompiler: &contentCompiler))
        }

        // If there are no manually curated topics, and no automatic groups, try generating automatic groups by child kind.
        if (article.topics == nil || article.topics?.taskGroups.isEmpty == true) &&
            article.automaticTaskGroups.isEmpty {
            // If there are no authored child topics in docs or markdown,
            // inspect the topic graph, find this node's children, and
            // for the ones found curate them automatically in task groups.
            // Automatic groups are named after the child's kind, e.g.
            // "Methods", "Variables", etc.
            let alreadyCurated = Set(node.topicSections.flatMap { $0.identifiers })
            let groups = try! AutomaticCuration.topics(for: documentationNode, context: context)
                .compactMap({ group -> AutomaticCuration.TaskGroup? in
                    // Remove references that have been already curated.
                    let newReferences = group.references.filter { !alreadyCurated.contains($0.absoluteString) }
                    // Remove groups that have no uncurated references
                    guard !newReferences.isEmpty else { return nil }

                    return (title: group.title, references: newReferences)
                })
            
            // Collect all child topic references.
            contentCompiler.collectedTopicReferences.append(contentsOf: groups.flatMap(\.references))
            // Add the final groups to the node.
            node.topicSections.append(contentsOf: groups.map(TaskGroupRenderSection.init(taskGroup:)))
        }
        
        // Place "bottom" rendering preference automatic task groups
        // after any user-defined task gruops but before automatic curation.
        if !article.automaticTaskGroups.isEmpty {
            node.topicSections.append(contentsOf: renderAutomaticTaskGroupsSection(article.automaticTaskGroups.filter({ $0.renderPositionPreference == .bottom }), contentCompiler: &contentCompiler))
        }

        if node.topicSections.isEmpty {
            // Set an eyebrow for articles
            node.metadata.roleHeading = "Article"
        }
        node.metadata.role = contentRenderer.roleForArticle(article, nodeKind: documentationNode.kind).rawValue

        // Authored See Also section
        if let seeAlso = article.seeAlso, !seeAlso.taskGroups.isEmpty {
            node.seeAlsoSections.append(contentsOf: renderGroups(seeAlso, allowExternalLinks: true, contentCompiler: &contentCompiler))
        }
        
        // Automatic See Also section
        if let seeAlso = try! AutomaticCuration.seeAlso(for: documentationNode, context: context, bundle: bundle, renderContext: renderContext, renderer: contentRenderer) {
            contentCompiler.collectedTopicReferences.append(contentsOf: seeAlso.references)
            node.seeAlsoSections.append(TaskGroupRenderSection(
                title: seeAlso.title,
                abstract: nil,
                discussion: nil,
                identifiers: seeAlso.references.map { $0.absoluteString },
                generated: true
            ))
        }
        
        collectedTopicReferences.append(contentsOf: contentCompiler.collectedTopicReferences)
        node.references = createTopicRenderReferences()

        addReferences(imageReferences, to: &node)
        addReferences(videoReferences, to: &node)
        addReferences(linkReferences, to: &node)
        // See Also can contain external links, we need to separately transfer
        // link references from the content compiler
        addReferences(contentCompiler.linkReferences, to: &node)

        return node
    }
    
    public mutating func visitTutorialArticle(_ article: TutorialArticle) -> RenderTree? {
        var node = RenderNode(identifier: identifier, kind: .article)
        
        var hierarchyTranslator = RenderHierarchyTranslator(context: context, bundle: bundle)
        guard let hierarchy = hierarchyTranslator.visitTechnologyNode(identifier) else {
            // This tutorial article is not curated, so we don't generate a render node.
            // We've warned about this during semantic analysis.
            return nil
        }
        
        let technology = try! context.entity(with: hierarchy.technology).semantic as! Technology
        
        node.metadata.title = article.title
        
        node.metadata.category = technology.name
        node.metadata.categoryPathComponent = hierarchy.technology.url.lastPathComponent
        node.metadata.role = contentRenderer.role(for: .tutorialArticle).rawValue
        
        // Unlike for other pages, in here we use `RenderHierarchyTranslator` to crawl the technology
        // and produce the list of modules for the render hierarchy to display in the tutorial local navigation.
        node.hierarchy = hierarchy.hierarchy
        
        
        collectedTopicReferences.append(contentsOf: hierarchyTranslator.collectedTopicReferences)
        
        var intro: IntroRenderSection
        if let articleIntro = article.intro {
            intro = visitIntro(articleIntro) as! IntroRenderSection
        } else {
            // Create a default intro section so that it's not an error to skip writing one.
            intro = IntroRenderSection(title: "")
        }
        
        if let time = article.durationMinutes {
            intro.estimatedTimeInMinutes = time
        }
        
        // Guaranteed to have at least one path
        let technologyPath = context.pathsTo(identifier, options: [.preferTechnologyRoot])[0]
                
        node.sections.append(intro)
        
        let layouts = contentLayouts(article.content)
        
        let articleSection = TutorialArticleSection(content: layouts)
        
        node.sections.append(articleSection)
        
        if let assessments = article.assessments {
            node.sections.append(visitAssessments(assessments) as! TutorialAssessmentsRenderSection)
        }
        
        if technologyPath.count >= 2 {
            let volume = technologyPath[technologyPath.count - 2]
            
            if let cta = callToAction(with: article.callToActionImage, volume: volume) {
                node.sections.append(cta)
            }
        }
        
        node.references = createTopicRenderReferences()

        addReferences(fileReferences, to: &node)
        addReferences(imageReferences, to: &node)
        addReferences(videoReferences, to: &node)
        addReferences(requirementReferences, to: &node)
        addReferences(downloadReferences, to: &node)
        addReferences(linkReferences, to: &node)
        
        return node
    }
    
    private mutating func contentLayouts<MarkupLayouts: Sequence>(_ markupLayouts: MarkupLayouts) -> [ContentLayout] where MarkupLayouts.Element == MarkupLayout {
        return markupLayouts.map { content in
            switch content {
            case .markup(let markup):
                return .fullWidth(content: visitMarkupContainer(markup) as! [RenderBlockContent])
            case .contentAndMedia(let contentAndMedia):
                return .contentAndMedia(content: visitContentAndMedia(contentAndMedia) as! ContentAndMediaSection)
            case .stack(let stack):
                return .columns(content: self.visitStack(stack) as! [ContentAndMediaSection])
            }
        }
    }
    
    public mutating func visitStack(_ stack: Stack) -> RenderTree? {
        return stack.contentAndMedia.map { self.visitContentAndMedia($0) as! ContentAndMediaSection } as [ContentAndMediaSection]
    }
    
    public mutating func visitComment(_ comment: Comment) -> RenderTree? {
        return nil
    }
    
    public mutating func visitDeprecationSummary(_ summary: DeprecationSummary) -> RenderTree? {
        return nil
    }

    /// The current module context for symbols.
    private var currentSymbolModuleName: String? = nil
    /// The current symbol context.
    private var currentSymbol: ResolvedTopicReference? = nil

    /// Renders automatically generated task groups
    private mutating func renderAutomaticTaskGroupsSection(_ taskGroups: [AutomaticTaskGroupSection], contentCompiler: inout RenderContentCompiler) -> [TaskGroupRenderSection] {
        return taskGroups.map { group in
            contentCompiler.collectedTopicReferences.append(contentsOf: group.references)
            return TaskGroupRenderSection(
                title: group.title,
                abstract: nil,
                discussion: nil,
                identifiers: group.references.compactMap(\.url?.absoluteString),
                generated: true
            )
        }
    }
    
    /// Renders a list of topic groups.
    private mutating func renderGroups(_ topics: GroupedSection, allowExternalLinks: Bool, contentCompiler: inout RenderContentCompiler) -> [TaskGroupRenderSection] {
        return topics.taskGroups.compactMap { group in
            
            let abstractContent = group.abstract.map {
                return visitMarkup($0.content) as! [RenderInlineContent]
            }
            
            let discussion = group.discussion.map { discussion -> ContentRenderSection in
                let discussionContent = visitMarkupContainer(MarkupContainer(discussion.content)) as! [RenderBlockContent]
                return ContentRenderSection(kind: .content, content: discussionContent, heading: "Discussion")
            }
            
            let taskGroupRenderSection = TaskGroupRenderSection(
                title: group.heading?.plainText,
                abstract: abstractContent,
                discussion: discussion,
                identifiers: group.links.compactMap { link in
                    switch link {
                    case let link as Link:
                        if !allowExternalLinks {
                            // For links require documentation scheme
                            guard let _ = link.destination.flatMap(ValidatedURL.init)?.requiring(scheme: ResolvedTopicReference.urlScheme) else {
                                return nil
                            }
                        }
                        
                        if let referenceInlines = contentCompiler.visitLink(link) as? [RenderInlineContent],
                            let renderReference = referenceInlines.first(where: { inline in
                            switch inline {
                            case .reference(_,_,_,_):
                                return true
                            default:
                                return false
                            }
                        }),
                           case let RenderInlineContent.reference(identifier: identifier, isActive: _, overridingTitle: _, overridingTitleInlineContent: _) = renderReference {
                            return identifier.identifier
                        }
                    case let link as SymbolLink:
                        if let referenceInlines = contentCompiler.visitSymbolLink(link) as? [RenderInlineContent],
                            let renderReference = referenceInlines.first(where: { inline in
                            switch inline {
                            case .reference:
                                return true
                            default:
                                return false
                            }
                        }),
                           case let RenderInlineContent.reference(identifier: identifier, isActive: _, overridingTitle: _, overridingTitleInlineContent: _) = renderReference {
                            return identifier.identifier
                        }
                    default: break
                    }
                    return nil
                }
            )
            
            // rdar://74617294 If a task group doesn't have any symbol or external links it shouldn't be rendered
            guard !taskGroupRenderSection.identifiers.isEmpty else {
                return nil
            }
            
            return taskGroupRenderSection
        }
    }
    
    @discardableResult
    private mutating func collectUnresolvableSymbolReference(destination: UnresolvedTopicReference, title: String) -> UnresolvedTopicReference? {
        guard let url = ValidatedURL(destination.topicURL.url) else {
            return nil
        }
        
        let reference = UnresolvedTopicReference(topicURL: url, title: title)
        collectedUnresolvedTopicReferences.append(reference)
        
        return reference
    }
    
    public mutating func visitSymbol(_ symbol: Symbol) -> RenderTree? {
        var node = RenderNode(identifier: identifier, kind: .symbol)
        var contentCompiler = RenderContentCompiler(context: context, bundle: bundle, identifier: identifier)

        currentSymbol = identifier
        
        /*
         FIXME: We shouldn't be doing this kind of crawling here.
         
         We should be doing a graph search to build up a breadcrumb and pass that to the translator, giving
         a definitive hierarchy before we even begin to build a RenderNode.
         */
        let documentationNode = try! context.entity(with: identifier)
        
        var ref = documentationNode.reference
        while let grandparent = context.parents(of: ref).first {
            ref = grandparent
        }

        node.metadata.modules = [RenderMetadata.Module(name: symbol.moduleName, relatedModules: symbol.bystanderModuleNames)]
        node.metadata.extendedModule = symbol.extendedModule
        node.metadata.platforms = (symbol.availability?.availability
            .compactMap { availability -> AvailabilityRenderItem? in
                // Filter items with insufficient availability data
                guard availability.introducedVersion != nil else {
                    return nil
                }
                guard let name = availability.domain.map({ PlatformName(operatingSystemName: $0.rawValue) }),
                    let currentPlatform = context.externalMetadata.currentPlatforms?[name.displayName] else {
                    // No current platform provided by the context
                    return AvailabilityRenderItem(availability, current: nil)
                }
                
                return AvailabilityRenderItem(availability, current: currentPlatform)
            } ?? defaultAvailability(for: bundle, moduleName: symbol.moduleName, currentPlatforms: context.externalMetadata.currentPlatforms))?
            .filter({ !($0.unconditionallyUnavailable == true) })
            .sorted(by: AvailabilityRenderOrder.compare)

        node.metadata.required = symbol.isRequired
        node.metadata.role = contentRenderer.role(for: documentationNode.kind).rawValue
        node.metadata.roleHeading = symbol.roleHeading
        node.metadata.title = symbol.title
        node.metadata.externalID = symbol.externalID
        // Remove any optional namespace (e.g. "swift.") for rendering
        node.metadata.symbolKind = symbol.kind.identifier.components(separatedBy: ".").last
        
        node.metadata.conformance = contentRenderer.conformanceSectionFor(identifier, collectedConstraints: collectedConstraints)
        node.metadata.fragments = contentRenderer.subHeadingFragments(for: documentationNode)
        node.metadata.navigatorTitle = contentRenderer.navigatorFragments(for: documentationNode)
        
        let generator = PresentationURLGenerator(context: context, baseURL: bundle.baseURL)
        node.variants = [
            .init(
                traits: [.interfaceLanguage(documentationNode.sourceLanguage.id)],
                paths: [
                    generator.presentationURLForReference(identifier).path
                ]
            )
        ]
        collectedTopicReferences.append(identifier)
        
        let contentRenderer = DocumentationContentRenderer(documentationContext: context, bundle: bundle)
        node.metadata.tags = contentRenderer.tags(for: identifier)

        var hierarchyTranslator = RenderHierarchyTranslator(context: context, bundle: bundle)
        let hierarchy = hierarchyTranslator.visitSymbol(identifier)
        collectedTopicReferences.append(contentsOf: hierarchyTranslator.collectedTopicReferences)
        node.hierarchy = hierarchy

        // In case `inheritDocs` is disabled and there is actually origin data for the symbol, then include origin information as abstract.
        // Generate the placeholder abstract only in case there isn't an authored abstract coming from a doc extension.
        if !context.externalMetadata.inheritDocs, let origin = (documentationNode.semantic as! Symbol).origin, symbol.abstractSection == nil {
            // Create automatic abstract for inherited symbols.
            node.abstract = [.text("Inherited from "), .codeVoice(code: origin.displayName), .text(".")]
        } else {
            // Create an abstract as usual.
            if let abstract = symbol.abstractSection?.content,
                let abstractContent = visitMarkup(abstract) as? [RenderInlineContent] {
                node.abstract = abstractContent
            } else {
                // Introduce a special behavior for generated bundles.
                if context.externalMetadata.isGeneratedBundle {
                    if documentationNode.kind != .module {
                        // Undocumented symbols get a default abstract.
                        node.abstract = [.text("No overview available.")]
                    } else {
                        // Undocumented module pages get an empty abstract.
                        node.abstract = [.text("")]
                    }
                } else {
                    // For non-generated bundles always add the default abstract.
                    node.abstract = [.text("No overview available.")]
                }
            }
        }

        if !symbol.declaration.isEmpty {
            var declarations = [DeclarationRenderSection]()
            
            for pair in symbol.declaration {
                let (platforms, declaration) = pair
                
                let renderedTokens = declaration.declarationFragments.map { token -> DeclarationRenderSection.Token in
                    
                    // Create a reference if one found
                    var reference: ResolvedTopicReference?
                    if let preciseIdentifier = token.preciseIdentifier,
                        let resolved = context.symbolIndex[preciseIdentifier]?.reference {
                        reference = resolved
                        
                        // Add relationship to render references
                        collectedTopicReferences.append(resolved)
                    }

                    // Add the declaration token
                    return DeclarationRenderSection.Token(fragment: token, identifier: reference?.absoluteString)
                }
                
                let platformNames = platforms.sorted { (lhs, rhs) -> Bool in
                    guard let lhsValue = lhs, let rhsValue = rhs else {
                        return lhs == nil
                    }
                    return lhsValue.rawValue < rhsValue.rawValue
                }
                
                declarations.append(
                    DeclarationRenderSection(languages: [identifier.sourceLanguage.id], platforms: platformNames, tokens: renderedTokens)
                )
            }
            
            node.primaryContentSections.append(
                DeclarationsRenderSection(declarations: declarations)
            )
        }
        
        if shouldEmitSymbolSourceFileURIs, let location = symbol.location {
            node.metadata.sourceFileURI = location.uri
        }
        
        if shouldEmitSymbolAccessLevels {
            node.metadata.symbolAccessLevel = symbol.accessLevel
        }
        
        if let returns = symbol.returnsSection, !returns.content.isEmpty,
            let returnsContent = visitMarkupContainer(MarkupContainer(returns.content)) as? [RenderBlockContent] {
            node.primaryContentSections.append(ContentRenderSection(kind: .content, content: returnsContent, heading: "Return Value"))
        }

        if let parameters = symbol.parametersSection, !parameters.parameters.isEmpty {
            let parametersSections: [ParameterRenderSection] = parameters.parameters
                .map { parameter in
                    let parameterContent = visitMarkupContainer(MarkupContainer(parameter.contents)) as! [RenderBlockContent]
                    return ParameterRenderSection(name: parameter.name, content: parameterContent)
                }

            node.primaryContentSections.append(ParametersRenderSection(parameters: parametersSections))
        }
                
        if let discussion = symbol.discussion,
            let discussionContent = visitMarkupContainer(MarkupContainer(discussion.content)) as? [RenderBlockContent],
            !discussionContent.isEmpty {
            
            let title: String?
            if let first = discussionContent.first, case RenderBlockContent.heading = first {
                // There's already an authored heading. Don't add another heading.
                title = nil
            } else {
                switch node.metadata.role.flatMap(RenderMetadata.Role.init) {
                case .dictionarySymbol?, .restRequestSymbol?:
                    title = "Discussion"
                case .symbol?:
                    if let swiftKind = SymbolGraph.Symbol.Kind.Swift(rawValue: symbol.kind.identifier) {
                        title = swiftKind.symbolCouldHaveChildren ? "Overview" : "Discussion"
                    } else {
                        title = "Discussion"
                    }
                default:
                    title = "Overview"
                }
            }
            node.primaryContentSections.append(ContentRenderSection(kind: .content, content: discussionContent, heading: title))
        }

        if !symbol.relationships.groups.isEmpty {
            var groupSections = [RelationshipsRenderSection]()
            
            let eligibleGroups = symbol.relationships.groups
                .sorted(by: { (group1, group2) -> Bool in
                    return group1.sectionOrder < group2.sectionOrder
                })
            
            for group in eligibleGroups {
                // destination url → symbol title
                var destinationsMap = [TopicReference: String]()
                
                for destination in group.destinations {
                    if let constraints = symbol.relationships.constraints[destination] {
                        collectedConstraints[destination] = constraints
                    }

                    switch destination {
                        case .resolved(let resolved):
                            let node = try! context.entity(with: resolved)
                            let resolver = LinkTitleResolver(context: context, source: resolved.url)
                            let resolvedTitle = resolver.title(for: node)
                            destinationsMap[destination] = resolvedTitle
                            
                            // Add relationship to render references
                            collectedTopicReferences.append(resolved)
                        case .unresolved(let unresolved):
                            // Try creating a render reference anyway
                            if let title = symbol.relationships.targetFallbacks[destination],
                                let reference = collectUnresolvableSymbolReference(destination: unresolved, title: title) {
                                destinationsMap[destination] = reference.title
                            }
                            continue
                    }
                }
                
                // Links section
                var orderedDestinations = Array(destinationsMap.keys)
                orderedDestinations.sort { destination1, destination2 -> Bool in
                    return destinationsMap[destination1]! <= destinationsMap[destination2]!
                }
                let groupSection = RelationshipsRenderSection(type: group.kind.rawValue, title: group.heading.plainText, identifiers: orderedDestinations.map({ $0.url!.absoluteString }))
                groupSections.append(groupSection)
            }
            node.relationshipSections.append(contentsOf: groupSections)
        }
        
        if let topics = symbol.topics, !topics.taskGroups.isEmpty {
            node.topicSections.append(contentsOf: renderGroups(topics, allowExternalLinks: false, contentCompiler: &contentCompiler))
        }
        
        // Place "top" rendering preference automatic task groups
        // after any user-defined task gruops but before automatic curation.
        if !symbol.automaticTaskGroups.isEmpty {
            node.topicSections.append(contentsOf: renderAutomaticTaskGroupsSection(symbol.automaticTaskGroups.filter({ $0.renderPositionPreference == .top }), contentCompiler: &contentCompiler))
        }

        /// Children of the current symbol that have not been curated manually in a task group will all
        /// be automatically curated in task groups after their symbol kind: "Properties", "Enumerations", etc.
        let alreadyCurated = Set(node.topicSections.flatMap { $0.identifiers })
        let groups = try! AutomaticCuration.topics(for: documentationNode, context: context)
        node.topicSections.append(contentsOf: groups.compactMap { group in
            let newReferences = group.references.filter { !alreadyCurated.contains($0.absoluteString) }
            guard !newReferences.isEmpty else { return nil }
            
            contentCompiler.collectedTopicReferences.append(contentsOf: newReferences)
            return TaskGroupRenderSection(
                title: group.title,
                abstract: nil,
                discussion: nil,
                identifiers: newReferences.map { $0.absoluteString }
            )
        })

        // Place "bottom" rendering preference automatic task groups
        // after any user-defined task gruops but before automatic curation.
        if !symbol.automaticTaskGroups.isEmpty {
            node.topicSections.append(contentsOf: renderAutomaticTaskGroupsSection(symbol.automaticTaskGroups.filter({ $0.renderPositionPreference == .bottom }), contentCompiler: &contentCompiler))
        }

        if !symbol.defaultImplementations.groups.isEmpty {
            for imp in symbol.defaultImplementations.implementations {
                let resolved: ResolvedTopicReference
                switch imp.reference {
                    case .resolved(let reference):
                        resolved = reference
                    case .unresolved(let unresolved):
                        // Try creating a render reference anyway
                        if let title = symbol.defaultImplementations.targetFallbacks[imp.reference],
                            let reference = collectUnresolvableSymbolReference(destination: unresolved, title: title),
                            let constraints = symbol.relationships.constraints[imp.reference] {
                            collectedConstraints[.unresolved(reference)] = constraints
                        }
                        continue
                }
                
                // Add implementation to render references
                collectedTopicReferences.append(resolved)
                if let constraints = symbol.relationships.constraints[imp.reference] {
                    collectedConstraints[.resolved(resolved)] = constraints
                }
            }
            
            node.defaultImplementationsSections.append(contentsOf:
                symbol.defaultImplementations.groups.map { group in
                    return TaskGroupRenderSection(title: group.heading, abstract: nil, discussion: nil, identifiers: group.references.map({ $0.url!.absoluteString }))
                }
            )
        }
        
        // If the symbol contains an authored See Also section from the documentation extension, add it as the first section under See Also.
        if let seeAlso = symbol.seeAlso {
            node.seeAlsoSections.append(contentsOf: renderGroups(seeAlso, allowExternalLinks: true, contentCompiler: &contentCompiler))
        }
        
        // Curate the current node's siblings as further See Also groups.
        if let seeAlso = try! AutomaticCuration.seeAlso(for: documentationNode, context: context, bundle: bundle, renderContext: renderContext, renderer: contentRenderer) {
            contentCompiler.collectedTopicReferences.append(contentsOf: seeAlso.references)
            node.seeAlsoSections.append(TaskGroupRenderSection(
                title: seeAlso.title,
                abstract: nil,
                discussion: nil,
                identifiers: seeAlso.references.map { $0.absoluteString },
                generated: true
            ))
        }
        
        // If there is a deprecation summary in a documentation extension file add it to the render node
        if let deprecated = symbol.deprecatedSummary,
            let deprecatedContent = visitMarkupContainer(MarkupContainer(deprecated.content)) as? [RenderBlockContent] {
            node.deprecationSummary = deprecatedContent
        }
        
        collectedTopicReferences.append(contentsOf: contentCompiler.collectedTopicReferences)
        node.references = createTopicRenderReferences()
        
        addReferences(imageReferences, to: &node)
        // See Also can contain external links, we need to separately transfer
        // link references from the content compiler
        addReferences(contentCompiler.linkReferences, to: &node)
        addReferences(linkReferences, to: &node)
        
        currentSymbol = nil
        return node
    }

    /// Creates a render reference for the given media and registers the reference to include it in the `references` dictionary.
    mutating func createAndRegisterRenderReference(forMedia media: ResourceReference?, poster: ResourceReference? = nil, altText: String? = nil, assetContext: DataAsset.Context = .display) -> RenderReferenceIdentifier {
        var mediaReference = RenderReferenceIdentifier("")
        guard let media = media else { return mediaReference }
        
        let fileExtension = NSString(string: media.path).pathExtension
        
        func resolveAsset() -> DataAsset? {
            renderContext?.store.content(
                forAssetNamed: media.path, bundleIdentifier: identifier.bundleIdentifier)
            ?? context.resolveAsset(named: media.path, in: identifier)
        }
        
        // Check if media is a supported image.
        if DocumentationContext.isFileExtension(fileExtension, supported: .image),
            let resolvedImages = resolveAsset()
        {
            mediaReference = RenderReferenceIdentifier(media.path)
            
            imageReferences[media.path] = ImageReference(
                identifier: mediaReference,
                // If no alt text has been provided and this image has been registered previously, use the registered alt text.
                altText: altText ?? imageReferences[media.path]?.altText,
                imageAsset: resolvedImages
            )
        }
        
        if DocumentationContext.isFileExtension(fileExtension, supported: .video),
           let resolvedVideos = resolveAsset()
        {
            mediaReference = RenderReferenceIdentifier(media.path)
            let poster = poster.map { createAndRegisterRenderReference(forMedia: $0) }
            videoReferences[media.path] = VideoReference(identifier: mediaReference, altText: altText, videoAsset: resolvedVideos, poster: poster)
        }
        
        if assetContext == DataAsset.Context.download, let resolvedDownload = resolveAsset() {
            // Create a download reference if possible.
            let downloadReference: DownloadReference
            do {            
                mediaReference = RenderReferenceIdentifier(media.path)
                let downloadURL = resolvedDownload.variants.first!.value
                let downloadData = try context.dataProvider.contentsOfURL(downloadURL, in: bundle)
                downloadReference = DownloadReference(identifier: mediaReference,
                    renderURL: downloadURL,
                    sha512Checksum: Checksum.sha512(of: downloadData))
            } catch {
                // It seems this is the way to error out of here.
                return mediaReference
            }

            // Add the file to the download references.
            mediaReference = RenderReferenceIdentifier(media.path)
            downloadReferences[media.path] = downloadReference
        }

        return mediaReference
    }
    
    var context: DocumentationContext
    var bundle: DocumentationBundle
    var identifier: ResolvedTopicReference
    var source: URL?
    var imageReferences: [String: ImageReference] = [:]
    var videoReferences: [String: VideoReference] = [:]
    var fileReferences: [String: FileReference] = [:]
    var linkReferences: [String: LinkReference] = [:]
    var requirementReferences: [String: XcodeRequirementReference] = [:]
    var downloadReferences: [String: DownloadReference] = [:]
    
    private var bundleAvailability: [BundleModuleIdentifier: [AvailabilityRenderItem]] = [:]
    
    /// Given module availability and the current platforms we're building against return if the module is a beta framework.
    private func isModuleBeta(moduleAvailability: DefaultAvailability.ModuleAvailability, currentPlatforms: [String: PlatformVersion]) -> Bool {
        guard
            // Check if we have a symbol availability version and a target platform version
            let moduleVersion = Version(versionString: moduleAvailability.platformVersion),
            // We require at least two components for a platform version (e.g. 10.15 or 10.15.1)
            moduleVersion.count >= 2,
            // Verify we're building against this platform
            let targetPlatformVersion = currentPlatforms[moduleAvailability.platformName.displayName],
            // Verify the target platform version is in beta
            targetPlatformVersion.beta else {
                return false
        }
        
        // Build a module availability version, defaulting the patch number to 0 if not provided (e.g. 10.15)
        let moduleVersionTriplet = VersionTriplet(moduleVersion[0], moduleVersion[1], moduleVersion.count > 2 ? moduleVersion[2] : 0)
        
        return moduleVersionTriplet == targetPlatformVersion.version
    }
    
    /// The default availability for modules in a given bundle and module.
    mutating func defaultAvailability(for bundle: DocumentationBundle, moduleName: String, currentPlatforms: [String: PlatformVersion]?) -> [AvailabilityRenderItem]? {
        let identifier = BundleModuleIdentifier(bundle: bundle, moduleName: moduleName)
        
        // Cached availability
        if let availability = bundleAvailability[identifier] {
            return availability
        }
        
        // Find default module availability if existing
        guard let bundleDefaultAvailability = bundle.defaultAvailability,
            let moduleAvailability = bundleDefaultAvailability.modules[moduleName] else {
            return nil
        }
        
        // Prepare for rendering
        let renderedAvailability = moduleAvailability
            .map({ availability -> AvailabilityRenderItem in
                return AvailabilityRenderItem(
                    name: availability.platformName.displayName,
                    introduced: availability.platformVersion,
                    isBeta: currentPlatforms.map({ isModuleBeta(moduleAvailability: availability, currentPlatforms: $0) }) ?? false
                )
            })
        
        // Cache the availability to use for further symbols
        bundleAvailability[identifier] = renderedAvailability
        
        // Return the availability
        return renderedAvailability
    }
    
    init(
        context: DocumentationContext,
        bundle: DocumentationBundle,
        identifier: ResolvedTopicReference,
        source: URL?,
        renderContext: RenderContext? = nil,
        emitSymbolSourceFileURIs: Bool = false,
        emitSymbolAccessLevels: Bool = false
    ) {
        self.context = context
        self.bundle = bundle
        self.identifier = identifier
        self.source = source
        self.renderContext = renderContext
        self.contentRenderer = DocumentationContentRenderer(documentationContext: context, bundle: bundle)
        self.shouldEmitSymbolSourceFileURIs = emitSymbolSourceFileURIs
        self.shouldEmitSymbolAccessLevels = emitSymbolAccessLevels
    }
}

fileprivate typealias BundleModuleIdentifier = String

extension BundleModuleIdentifier {
    fileprivate init(bundle: DocumentationBundle, moduleName: String) {
        self = "\(bundle.identifier):\(moduleName)"
    }
}

public protocol RenderTree {}
extension Array: RenderTree where Element: RenderTree {}
extension RenderBlockContent: RenderTree {}
extension RenderReferenceIdentifier: RenderTree {}
extension RenderNode: RenderTree {}
extension IntroRenderSection: RenderTree {}
extension VolumeRenderSection: RenderTree {}
extension VolumeRenderSection.Chapter: RenderTree {}
extension ContentAndMediaSection: RenderTree {}
extension ContentAndMediaGroupSection: RenderTree {}
extension CallToActionSection: RenderTree {}
extension TutorialSectionsRenderSection: RenderTree {}
extension TutorialSectionsRenderSection.Section: RenderTree {}
extension TutorialAssessmentsRenderSection: RenderTree {}
extension TutorialAssessmentsRenderSection.Assessment: RenderTree {}
extension TutorialAssessmentsRenderSection.Assessment.Choice: RenderTree {}
extension RenderInlineContent: RenderTree {}
extension RenderTile: RenderTree {}
extension ResourcesRenderSection: RenderTree {}
extension TutorialArticleSection: RenderTree {}
extension ContentLayout: RenderTree {}

extension ContentRenderSection: RenderTree {}
