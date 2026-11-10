import Foundation
import Testing
import FloeLaTeXCore
import FloeLaTeXParsing

private actor PlanAdmissionGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}

@Suite("RQ29 coherent project dependency candidates and failed-compiler feedback", .serialized)
struct DependencyPlanTests {
    func fixture(_ files: [String: String], assets: [String: Data] = [:], main: String = "main.tex", engine: LaTeXEngine = .xeLaTeX,
                 revision: Int64 = 4) -> (LaTeXProjectManifest, [String: String]) {
        var manifest = LaTeXProjectManifest(owner: .init(kind: .space, id: UUID()), title: "Fixture", mainFile: main, engine: engine)
        manifest.revision = revision
        manifest.files = files.map { .init(path: $0.key, data: Data($0.value.utf8)) } + assets.map { .init(path: $0.key, data: $0.value) }
        manifest.files.sort { $0.path < $1.path }
        return (manifest, files)
    }
    func plan(_ files: [String: String], assets: [String: Data] = [:]) throws -> LaTeXDependencyPlan {
        let (manifest, captured) = fixture(files, assets: assets)
        return try LaTeXDependencyPlanner.plan(manifest: manifest, textFiles: captured)
    }
    func names(_ plan: LaTeXDependencyPlan, kind: LaTeXDependencyRequirement.Kind = .texFile) -> Set<String> {
        Set(plan.requirements.filter { $0.kind == kind }.map(\.value))
    }

    @Test("Ordinary English plans the actual engine/class/package without introducing an installation profile")
    func plainEnglishNeedsOnlyReferencedCandidates() throws {
        let (manifest, files) = fixture(["main.tex": #"\documentclass{article}\usepackage{amsmath}\begin{document}Hello\end{document}"#], engine: .pdfLaTeX)
        let value = try LaTeXDependencyPlanner.plan(manifest: manifest, textFiles: files)
        #expect(names(value) == ["article.cls", "amsmath.sty"])
        #expect(names(value, kind: .program) == ["pdflatex"])
        #expect(value.revision == manifest.revision && value.projectID == manifest.id && value.mainFile == "main.tex")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        #expect(encoded?["requiresCompilerFeedback"] as? Bool == true)
    }
    @Test("Comments, verbatim and ordinary macro definitions are not live package requirements")
    func lexerSkipsInactiveSourceText() throws {
        let source = #"""
        % \usepackage{commented}
        \documentclass{article}
        \newcommand{\demo}{\usepackage{inDefinition}}
        \begin{verbatim}
        \usepackage{inVerbatim}
        \end{verbatim}
        \verb|\usepackage{inVerb}|
        \usepackage{real}
        """#
        #expect(names(try plan(["main.tex": source])) == ["article.cls", "real.sty"])
    }
    @Test("Unbraced def and newcommand bodies remain definitions rather than causing unrelated downloads")
    func unbracedDefinitionsDoNotRequestBodyPackages() throws {
        let source = #"""
        \documentclass{article}
        \def\hidden#1{\usepackage{hiddenByDef}}
        \newcommand\other[1]{\RequirePackage{hiddenByNewcommand}}
        \usepackage{actual}
        """#
        #expect(names(try plan(["main.tex": source])) == ["article.cls", "actual.sty"])
    }
    @Test("A project class/style/include graph is traversed once, including cycles, while unused files stay unused")
    func localOriginalsPrecedeSystemPackages() throws {
        let files = ["main.tex": #"\documentclass{custom}\usepackage{local}\input{chapters/one}"#,
                     "custom.cls": #"\LoadClass{article}\RequirePackage{xcolor}"#,
                     "styles/local.sty": #"\RequirePackage{amsmath}\input{chapters/one}"#,
                     "chapters/one.tex": #"\input{main}\usepackage{tikz}"#,
                     "unused.tex": #"\usepackage{unusedHugePackage}"#]
        let value = try plan(files)
        #expect(names(value) == ["article.cls", "xcolor.sty", "amsmath.sty", "tikz.sty"])
        #expect(Set(value.inspectedFiles) == ["main.tex", "custom.cls", "styles/local.sty", "chapters/one.tex"])
        #expect(!names(value).contains("custom.cls") && !names(value).contains("local.sty"))
    }
    @Test("Chinese class and explicit system-font declarations stay separate resource requests")
    func chineseAndFontDeclarationsAreTyped() throws {
        let value = try plan(["main.tex": #"\documentclass{ctexbook}\usepackage{fontspec}\setmainfont{TeX Gyre Termes}\setCJKmainfont{Noto Serif CJK SC}"#])
        #expect(names(value) == ["ctexbook.cls", "fontspec.sty"])
        #expect(names(value, kind: .fontFamily) == ["TeX Gyre Termes", "Noto Serif CJK SC"])
    }
    @Test("APA/biblatex resolves local bibliography, styles and the selected Biber backend")
    func bibliographyHasSourceAndProgramDependencies() throws {
        let value = try plan(["main.tex": #"\documentclass{apa7}\usepackage[style=apa,backend=biber]{biblatex}\addbibresource{references.bib}"#,
                              "references.bib": "@book{fixture,title={Fixture}}"])
        #expect(names(value).isSuperset(of: ["apa7.cls", "biblatex.sty", "apa.bbx", "apa.cbx"]))
        #expect(names(value, kind: .program).contains("biber"))
        #expect(value.projectReferences.contains { $0.kind == .bibliography && $0.resolvedPaths == ["references.bib"] })
        let legacy = try plan(["main.tex": #"\bibliographystyle{apalike}\bibliography{refs}"#, "refs.bib": "@book{x,title={X}}"])
        #expect(names(legacy).contains("apalike.bst") && names(legacy, kind: .program).contains("bibtex"))
    }
    @Test("Skipping a definition retains its exact Unicode source range and leaves the following real command indexed")
    func definitionRangeRemainsLossless() throws {
        let definition = #"\def\hidden#1{文字\label{hiddenLabel}\usepackage{hiddenPackage}}"#
        let parsed = LaTeXParser.parse(definition + "\n" + #"\section{Visible}"#)
        let command = try #require(parsed.commands.first { $0.name == "def" })
        #expect(parsed.original(command.range) == definition)
        #expect(parsed.labels.isEmpty && parsed.packages.isEmpty)
        #expect(parsed.commands.contains { $0.name == "section" && $0.arguments.first?.value == "Visible" })
    }
    @Test("An unbraced constructor with a default parameter skips both default and body without consuming its neighbor")
    func unbracedConstructorOptionsStayBounded() throws {
        let source = #"\providecommand\hidden[1][{default}]{\RequirePackage{inBody}}\usepackage{outside}"#
        let value = try plan(["main.tex": source])
        #expect(names(value) == ["outside.sty"])
    }
    @Test("Project fonts and graphics are reused by original path and never converted into package or URL installs")
    func bundledFontAndGraphicResourcesStayLocal() throws {
        let value = try plan(["main.tex": #"\setmainfont[Path=fonts/,Extension=.otf]{MyFont}\includegraphics{figures/result}"#],
                             assets: ["fonts/MyFont.otf": Data([0,1]), "figures/result.pdf": Data([2,3])])
        #expect(value.projectReferences.contains { $0.kind == .font && $0.resolvedPaths == ["fonts/MyFont.otf"] })
        #expect(value.projectReferences.contains { $0.kind == .graphic && $0.resolvedPaths == ["figures/result.pdf"] })
        #expect(names(value, kind: .fontFamily).isEmpty && value.issues.isEmpty)
    }
    @Test("Literal unbraced inputs and comma-list comments follow the parsed source graph")
    func standardInputAndCommentsAreResolved() throws {
        let value = try plan(["main.tex": "\\usepackage{amsmath,% kept comment\n amssymb}\n\\input chapter\n", "chapter.tex": #"\RequirePackage{booktabs}"#])
        #expect(names(value) == ["amsmath.sty", "amssymb.sty", "booktabs.sty"])
        #expect(Set(value.inspectedFiles) == ["main.tex", "chapter.tex"])
    }
    @Test("Ambiguous local names do not choose an arbitrary file or fetch a same-named system replacement")
    func ambiguousProjectResourcesRemainExplicit() throws {
        let value = try plan(["main.tex": #"\usepackage{custom}"#, "a/custom.sty": #"\RequirePackage{one}"#, "b/custom.sty": #"\RequirePackage{two}"#])
        #expect(names(value).isEmpty)
        #expect(value.issues.contains { $0.kind == .ambiguousProjectResource })
        #expect(value.inspectedFiles == ["main.tex"])
    }
    @Test("Macro-dependent, external and missing local references stay actionable without inventing an install command")
    func unresolvedInputsAreNotPretendedComplete() throws {
        let value = try plan(["main.tex": #"\usepackage{\myPackage}\addbibresource{https://example.invalid/refs.bib}\input{missing/chapter}"#])
        #expect(value.issues.contains { $0.kind == .dynamicReference })
        #expect(value.issues.contains { $0.kind == .externalReference })
        #expect(value.issues.contains { $0.kind == .missingProjectResource })
        #expect(value.requiresCompilerFeedback && names(value).isEmpty)
    }
    @Test("The plan rejects a modified or undeclared text input instead of reusing an old revision's authority")
    func coherentRevisionAndHashAreMandatory() throws {
        let (manifest, files) = fixture(["main.tex": #"\documentclass{article}"#])
        var changed = files; changed["main.tex"] = #"\documentclass{book}"#
        #expect(throws: LaTeXError.self) { try LaTeXDependencyPlanner.plan(manifest: manifest, textFiles: changed) }
        var extra = files; extra["unmanifested.tex"] = "Other"
        #expect(throws: LaTeXError.self) { try LaTeXDependencyPlanner.plan(manifest: manifest, textFiles: extra) }
        var new = manifest; new.revision += 1
        let oldPlan = try LaTeXDependencyPlanner.plan(manifest: manifest, textFiles: files)
        let newPlan = try LaTeXDependencyPlanner.plan(manifest: new, textFiles: files)
        #expect(oldPlan.inputDigest != newPlan.inputDigest && oldPlan.revision != newPlan.revision)
    }
    @Test("Real failed-compiler missing files/fonts/tools supplement the same plan without treating images or shell text as packages")
    func compilerFeedbackIsTypedAndInputBound() throws {
        let initial = try plan(["main.tex": #"\documentclass{article}"#])
        let messages = ["! LaTeX Error: File `indirect.sty' not found.", "! LaTeX Error: File `picture.png' not found.",
                        "Package fontspec Error: The font \"Missing Font\" cannot be found.", "This document requires biber in the selected environment",
                        "! LaTeX Error: File `x;touch bad.sty' not found."]
        let updated = try LaTeXDependencyPlanner.supplement(initial, compilerMessages: messages)
        #expect(names(updated) == ["article.cls", "indirect.sty"])
        #expect(names(updated, kind: .fontFamily) == ["Missing Font"] && names(updated, kind: .program).contains("biber"))
        #expect(updated.projectID == initial.projectID && updated.revision == initial.revision && updated.inputDigest == initial.inputDigest)
        let repeated = try LaTeXDependencyPlanner.supplement(updated, compilerMessages: messages)
        #expect(repeated == updated)
    }
    @Test("Cancelled preparation stops before scanning rather than returning a completed dependency plan")
    func cancelledPlanCannotClaimReadiness() async {
        let (manifest, files) = fixture(["main.tex": #"\usepackage{amsmath}"#])
        let gate = PlanAdmissionGate()
        let task = Task.detached { await gate.wait(); return try LaTeXDependencyPlanner.plan(manifest: manifest, textFiles: files) }
        task.cancel()
        await gate.open()
        let result = await task.result
        switch result { case .success: Issue.record("Cancelled plan returned success"); case .failure(let error): #expect(error is CancellationError) }
    }
}
