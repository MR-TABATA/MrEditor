import XCTest
@testable import MrEditorCore

/// コード言語ごとの軽量ハイライト（コメント・文字列・数値・予約語）。
/// 「コメント記号が文字列の中にあっても誤検出しない」が一番壊れやすい点なので、
/// 各言語で最低 1 本はその確認を入れる。
final class CodeSyntaxTests: XCTestCase {
    private func spans(_ text: String, _ language: CodeSyntax.Language) -> [CodeSyntax.Span] {
        CodeSyntax.spans(text: text as NSString, language: language)
    }
    private func role(_ spans: [CodeSyntax.Span], _ role: CodeSyntax.Role) -> [NSRange] {
        spans.filter { $0.role == role }.map { $0.range }
    }

    // MARK: - 拡張子判定

    func testExtensionDetection() {
        XCTAssertEqual(CodeSyntax.Language.detect(extension: "py"), .python)
        XCTAssertEqual(CodeSyntax.Language.detect(extension: "ts"), .javascript)
        XCTAssertEqual(CodeSyntax.Language.detect(extension: "YML"), nil)   // 呼び出し側で小文字化する前提
        XCTAssertEqual(CodeSyntax.Language.detect(extension: "yml"), .yaml)
        XCTAssertNil(CodeSyntax.Language.detect(extension: "md"))          // Markdown は別経路
        XCTAssertEqual(CodeSyntax.Language.detect(extension: "java"), .java)
        XCTAssertEqual(CodeSyntax.Language.detect(extension: "php"), .php)
        XCTAssertEqual(CodeSyntax.Language.detect(extension: "go"), .go)
        XCTAssertEqual(CodeSyntax.Language.detect(extension: "rb"), .ruby)
        XCTAssertEqual(CodeSyntax.Language.detect(extension: "pl"), .perl)
        XCTAssertEqual(CodeSyntax.Language.detect(extension: "pm"), .perl)
    }

    // MARK: - Java

    func testJavaKeywordsAndBlockComment() {
        let text = "/* note */ public class Foo { boolean ok = true; }"
        let spans = self.spans(text, .java)
        XCTAssertEqual(role(spans, .comment).count, 1)
        XCTAssertTrue(role(spans, .keyword).contains { (text as NSString).substring(with: $0) == "public" })
        XCTAssertTrue(role(spans, .keyword).contains { (text as NSString).substring(with: $0) == "true" })
    }

    // MARK: - PHP（// と # の両方が行コメント）

    func testPhpBothLineCommentStyles() {
        let text = "echo \"hi\"; // one\n# two"
        let spans = self.spans(text, .php)
        XCTAssertEqual(role(spans, .comment).count, 2)
        XCTAssertTrue(role(spans, .keyword).contains { (text as NSString).substring(with: $0) == "echo" })
    }

    // MARK: - Go

    func testGoKeywordsAndString() {
        let text = "func main() {\n\tx := \"hi\" // greet\n}"
        let spans = self.spans(text, .go)
        XCTAssertTrue(role(spans, .keyword).contains { (text as NSString).substring(with: $0) == "func" })
        XCTAssertEqual(role(spans, .string).count, 1)
        XCTAssertEqual(role(spans, .comment).count, 1)
    }

    // MARK: - Ruby（# はコメント、文字列の中の # は誤検出しない）

    func testRubyCommentDoesNotStartInsideString() {
        let text = "puts \"a # not a comment\" # real"
        let spans = self.spans(text, .ruby)
        XCTAssertEqual(role(spans, .comment).count, 1)
        let comment = role(spans, .comment)[0]
        XCTAssertEqual((text as NSString).substring(with: comment), "# real")
    }

    func testRubyKeyword() {
        XCTAssertTrue(role(spans("def foo; end", .ruby), .keyword).count == 2)
    }

    // MARK: - Perl

    func testPerlKeywordAndComment() {
        let text = "my $x = 1; # comment"
        let spans = self.spans(text, .perl)
        XCTAssertTrue(role(spans, .keyword).contains { (text as NSString).substring(with: $0) == "my" })
        XCTAssertEqual(role(spans, .comment).count, 1)
    }

    // MARK: - Python

    func testPythonCommentDoesNotStartInsideString() {
        let text = "x = \"a # not a comment\"  # real comment"
        let spans = self.spans(text, .python)
        XCTAssertEqual(role(spans, .comment).count, 1)
        let comment = role(spans, .comment)[0]
        XCTAssertEqual((text as NSString).substring(with: comment), "# real comment")
    }

    func testPythonKeywordAndTripleQuotedString() {
        let text = "def f():\n    \"\"\"multi\nline\"\"\"\n    return True"
        let spans = self.spans(text, .python)
        XCTAssertEqual(role(spans, .keyword).count, 3)   // def, return, True
        XCTAssertEqual(role(spans, .string).count, 1)
        let str = role(spans, .string)[0]
        XCTAssertEqual((text as NSString).substring(with: str), "\"\"\"multi\nline\"\"\"")
    }

    // MARK: - Swift

    func testSwiftBlockCommentAndString() {
        let text = "let x = /* note \"//not-a-string\" */ \"hi\""
        let spans = self.spans(text, .swift)
        XCTAssertEqual(role(spans, .comment).count, 1)
        XCTAssertEqual(role(spans, .string).count, 1)
        XCTAssertTrue(role(spans, .keyword).contains { (text as NSString).substring(with: $0) == "let" })
    }

    // MARK: - JavaScript/TypeScript

    func testJavascriptLineCommentInsideStringIsNotAComment() {
        let text = "const url = \"http://example.com\"; // real"
        let spans = self.spans(text, .javascript)
        XCTAssertEqual(role(spans, .string).count, 1)
        XCTAssertEqual(role(spans, .comment).count, 1)
        let comment = role(spans, .comment)[0]
        XCTAssertEqual((text as NSString).substring(with: comment), "// real")
    }

    // MARK: - Shell

    func testShellHashInsideStringIsNotAComment() {
        let text = "echo \"a # b\" # real comment"
        let spans = self.spans(text, .shell)
        XCTAssertEqual(role(spans, .comment).count, 1)
        let comment = role(spans, .comment)[0]
        XCTAssertEqual((text as NSString).substring(with: comment), "# real comment")
    }

    // MARK: - YAML（真偽値は大文字小文字を問わない・キーが主役）

    func testYamlBooleanCaseInsensitive() {
        let text = "a: true\nb: FALSE\nc: yes"
        let spans = self.spans(text, .yaml)
        XCTAssertEqual(role(spans, .keyword).count, 3)
    }

    func testYamlKeyIsDefinition() {
        let text = "name: sample\nnested:\n  child: 1"
        let spans = self.spans(text, .yaml)
        let defs = role(spans, .definition).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(Set(defs), ["name", "nested", "child"])
    }

    func testYamlListItemKeyStillDetected() {
        let text = "items:\n  - name: alice\n  - name: bob"
        let spans = self.spans(text, .yaml)
        let defs = role(spans, .definition).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(defs.filter { $0 == "name" }.count, 2)
    }

    func testYamlCommentInsideQuoteIsNotAComment() {
        let text = "note: \"a # not a comment\" # real"
        let spans = self.spans(text, .yaml)
        XCTAssertEqual(role(spans, .comment).count, 1)
        let comment = role(spans, .comment)[0]
        XCTAssertEqual((text as NSString).substring(with: comment), "# real")
    }

    func testYamlQuotedTrueIsStringNotKeyword() {
        let text = "flag: \"true\""
        let spans = self.spans(text, .yaml)
        XCTAssertEqual(role(spans, .string).count, 1)
        XCTAssertEqual(role(spans, .keyword).count, 0)
    }

    // MARK: - JSON（コメントは無い）

    func testJsonHasNoComments() {
        let text = "{\"a\": 1} // not a comment in strict JSON"
        let spans = self.spans(text, .json)
        XCTAssertEqual(role(spans, .comment).count, 0)
        XCTAssertEqual(role(spans, .number).count, 1)
    }

    func testJsonLiterals() {
        let text = "{\"a\": true, \"b\": null}"
        XCTAssertEqual(role(spans(text, .json), .keyword).count, 2)
    }

    // MARK: - SQL（予約語は大文字小文字を問わない）

    func testSqlKeywordsCaseInsensitive() {
        let text = "select * from Users where id = 1"
        let spans = self.spans(text, .sql)
        XCTAssertTrue(role(spans, .keyword).count >= 3)   // select, from, where
        XCTAssertEqual(role(spans, .number).count, 1)
    }

    func testSqlDashCommentInsideStringIsNotAComment() {
        let text = "select '--not a comment' -- real"
        let spans = self.spans(text, .sql)
        XCTAssertEqual(role(spans, .string).count, 1)
        XCTAssertEqual(role(spans, .comment).count, 1)
    }

    // MARK: - CSS（予約語は無い。コメントと文字列だけ）

    func testCssBlockComment() {
        let text = "/* note */ .a { color: \"red\"; }"
        let spans = self.spans(text, .css)
        XCTAssertEqual(role(spans, .comment).count, 1)
        XCTAssertEqual(role(spans, .string).count, 1)
        XCTAssertEqual(role(spans, .keyword).count, 0)
    }

    // MARK: - 宣言名（def/class/func などの直後の識別子）

    func testPythonDefinitionNames() {
        let text = "def greet():\n    pass\nclass Greeter:\n    pass"
        let spans = self.spans(text, .python)
        let defs = role(spans, .definition).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(defs, ["greet", "Greeter"])
    }

    func testSwiftDefinitionName() {
        let text = "func greet(name: String) {}"
        let spans = self.spans(text, .swift)
        let defs = role(spans, .definition).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(defs, ["greet"])
    }

    func testJavascriptDefinitionName() {
        let text = "function greet() {}\nclass Greeter {}"
        let spans = self.spans(text, .javascript)
        let defs = role(spans, .definition).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(defs, ["greet", "Greeter"])
    }

    func testJavaDefinitionName() {
        let defs = role(spans("public class Greeter {}", .java), .definition)
            .map { ("public class Greeter {}" as NSString).substring(with: $0) }
        XCTAssertEqual(defs, ["Greeter"])
    }

    func testPhpDefinitionName() {
        let text = "function greet() {}"
        XCTAssertEqual(role(spans(text, .php), .definition).map { (text as NSString).substring(with: $0) },
                       ["greet"])
    }

    func testRubyDefinitionName() {
        let text = "def greet\nend"
        XCTAssertEqual(role(spans(text, .ruby), .definition).map { (text as NSString).substring(with: $0) },
                       ["greet"])
    }

    func testPerlDefinitionName() {
        let text = "sub greet {}"
        XCTAssertEqual(role(spans(text, .perl), .definition).map { (text as NSString).substring(with: $0) },
                       ["greet"])
    }

    /// レシーバ付きメソッドは名前の手前に空白以外の文字（`(`）が挟まるので、
    /// 誤って `r` を宣言名にしない（対象外のまま・安全側）。
    func testGoDefinitionNameSkipsReceiverMethods() {
        let plain = "func main() {}"
        XCTAssertEqual(role(spans(plain, .go), .definition).map { (plain as NSString).substring(with: $0) },
                       ["main"])

        let withReceiver = "func (g *Greeter) Greet() {}"
        XCTAssertEqual(role(spans(withReceiver, .go), .definition).count, 0)
    }
}
