import XCTest
@testable import Xipixiaojuchang

/// 提示词里「文字与缩略图混排」那几行的文字拆块：拆开再拼回去必须一字不差，且不能把标点拆到行首、开括号拆到行尾。
final class PromptTextPiecesTests: XCTestCase {
    func testPiecesJoinBackToOriginal() {
        for text in ["", "，坐下。", "站在窗边，目光看向远处，神情复杂。", "walk to the door, then turn left.", "说：“你终于来了。”  末尾有空格 ",
                     "【角色初始站位与朝向】站在画面左侧；A、B 两人 ok？", "镜头 push-in 到 3.5 米处…… 然后停住——"] {
            XCTAssertEqual(PromptTextPieces.split(text).joined(), text)
        }
    }

    func testChineseSplitsPerCharacterAndKeepsPunctuationWithPrevious() {
        XCTAssertEqual(PromptTextPieces.split("站在窗边，目光。"), ["站", "在", "窗", "边，目", "光。"])
    }

    func testNoPieceStartsWithClosingPunctuationOrEndsWithOpener() {
        let text = "他说：“走吧。”然后（很慢地）转身，走向【门口】；再回头。"
        let pieces = PromptTextPieces.split(text)
        for (i, piece) in pieces.enumerated() where i > 0 {
            XCTAssertFalse("，。、；：！？）】》”’".contains(piece.first!), "第 \(i) 块以标点开头：\(piece)")
        }
        for piece in pieces {
            XCTAssertFalse("（【《“‘「".contains(piece.last!), "以开括号结尾：\(piece)")
        }
    }

    func testLatinWordsStayWhole() {
        XCTAssertEqual(PromptTextPieces.split("push-in to door 3.5m"), ["push-in ", "to ", "door ", "3.5m"])
        XCTAssertEqual(PromptTextPieces.split("走到door前"), ["走", "到", "door", "前"])
    }

    func testLeadingPunctuationAfterThumbnailAbsorbsNextCharacter() {
        XCTAssertEqual(PromptTextPieces.split("，坐下。"), ["，坐", "下。"])
    }
}
