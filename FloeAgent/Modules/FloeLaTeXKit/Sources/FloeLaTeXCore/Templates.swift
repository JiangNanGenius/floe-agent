// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct LaTeXTemplate: Sendable, Identifiable {
    public var id: String
    public var englishTitle: String
    public var chineseTitle: String
    public var engine: LaTeXEngine
    public var files: [String:Data]
    public var mainFile: String
    public init(id:String,englishTitle:String,chineseTitle:String,engine:LaTeXEngine = .xeLaTeX,source:String,bibliography:Bool = false) {
        self.id=id;self.englishTitle=englishTitle;self.chineseTitle=chineseTitle;self.engine=engine;mainFile="main.tex";files=["main.tex":Data(source.utf8)]
        if bibliography { files["references.bib"] = Data("% Add your references here.\n".utf8) }
    }
}
public enum LaTeXTemplates {
    private static let base: [LaTeXTemplate] = [
        .init(id:"article",englishTitle:"Research article",chineseTitle:"学术论文",source:#"""
        \documentclass[11pt,a4paper]{article}
        \usepackage{amsmath,amssymb,graphicx,booktabs,hyperref}
        \usepackage[margin=2.5cm]{geometry}
        \title{Untitled article}
        \author{}
        \date{\today}
        \begin{document}
        \maketitle
        \begin{abstract}
        Write your abstract here.
        \end{abstract}
        \section{Introduction}
        Start writing here.
        \section{Methods}
        \begin{equation}\label{eq:example}
        E = mc^2
        \end{equation}
        \section{Results}
        Refer to Equation~\ref{eq:example}.
        \section{Conclusion}
        \bibliographystyle{plain}
        % \bibliography{references}
        \end{document}
        """# + "\n",bibliography:true),
        .init(id:"chinese",englishTitle:"Chinese article",chineseTitle:"中文论文",source:#"""
        \documentclass[UTF8,fontset=fandol,a4paper]{ctexart}
        \usepackage{amsmath,amssymb,graphicx,booktabs,hyperref}
        \usepackage[margin=2.5cm]{geometry}
        \title{未命名论文}
        \author{}
        \date{\today}
        \begin{document}
        \maketitle
        \begin{abstract}
        在这里填写摘要。
        \end{abstract}
        \section{引言}
        在这里开始写作。
        \section{研究方法}
        \begin{equation}\label{eq:example}
        E = mc^2
        \end{equation}
        \section{结果与讨论}
        \section{结论}
        \bibliographystyle{plain}
        % \bibliography{references}
        \end{document}
        """# + "\n",bibliography:true),
        .init(id:"thesis",englishTitle:"Thesis",chineseTitle:"毕业论文",source:#"""
        \documentclass[UTF8,fontset=fandol,openany,a4paper]{ctexbook}
        \usepackage{amsmath,amssymb,graphicx,booktabs,longtable,hyperref}
        \usepackage[margin=2.5cm]{geometry}
        \title{论文标题}
        \author{}
        \begin{document}
        \frontmatter
        \maketitle
        \chapter{摘要}
        在这里填写摘要。
        \tableofcontents
        \listoffigures
        \listoftables
        \mainmatter
        \include{chapters/introduction}
        \chapter{研究方法}
        \chapter{结果与讨论}
        \chapter{结论}
        \backmatter
        \bibliographystyle{plain}
        % \bibliography{references}
        \end{document}
        """# + "\n",bibliography:true),
        .init(id:"report",englishTitle:"Report",chineseTitle:"研究报告",source:#"""
        \documentclass[11pt,a4paper]{report}
        \usepackage{amsmath,graphicx,booktabs,hyperref}
        \title{Report}
        \author{}
        \begin{document}
        \maketitle
        \tableofcontents
        \chapter{Introduction}
        Start writing here.
        \chapter{Analysis}
        \chapter{Conclusion}
        \end{document}
        """# + "\n"),
        .init(id:"book",englishTitle:"Book",chineseTitle:"书籍",source:#"""
        \documentclass[11pt,openany]{book}
        \usepackage{amsmath,graphicx,hyperref}
        \title{Book title}
        \author{}
        \begin{document}
        \frontmatter
        \maketitle
        \tableofcontents
        \mainmatter
        \chapter{First chapter}
        Start writing here.
        \backmatter
        \end{document}
        """# + "\n"),
        .init(id:"presentation",englishTitle:"Presentation",chineseTitle:"演示文稿",source:#"""
        \documentclass{beamer}
        \usepackage{amsmath,graphicx}
        \usetheme{Madrid}
        \title{Presentation}
        \author{}
        \begin{document}
        \frame{\titlepage}
        \begin{frame}{Introduction}
        \begin{itemize}
        \item First point
        \item Second point
        \end{itemize}
        \end{frame}
        \end{document}
        """# + "\n"),
        .init(id:"diagram",englishTitle:"Diagrams and plots",chineseTitle:"图形与绘图",source:#"""
        \documentclass{article}
        \usepackage{tikz,pgfplots}
        \pgfplotsset{compat=1.18}
        \begin{document}
        \section{Diagram}
        \begin{tikzpicture}
        \node[draw] (a) at (0,0) {Input};
        \node[draw] (b) at (3,0) {Output};
        \draw[->] (a) -- (b);
        \end{tikzpicture}
        \section{Plot}
        \begin{tikzpicture}
        \begin{axis}[xlabel={$x$},ylabel={$y$}]
        \addplot[domain=-2:2]{x^2};
        \end{axis}
        \end{tikzpicture}
        \end{document}
        """# + "\n")
    ]
    public static let all: [LaTeXTemplate] = {
        var values = base
        if let index = values.firstIndex(where: { $0.id == "thesis" }) {
            values[index].files["chapters/introduction.tex"] = Data("\\chapter{引言}\n在这里开始写作。\n".utf8)
        }
        return values
    }()
    public static func template(_ id: String) -> LaTeXTemplate { all.first { $0.id == id } ?? all[0] }
}
