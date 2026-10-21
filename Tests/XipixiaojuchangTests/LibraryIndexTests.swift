import XCTest
@testable import Xipixiaojuchang

/// `AppModel.libraryItem(_:)` 用下标缓存查（2026-10-10：工作台一页要问几百次，库里上千条时原来每次线性找，切一段要几十毫秒）。
/// 缓存不能出错：加 / 删 / 改顺序 / 原地改某一条之后，查到的都得是对的。
@MainActor
final class LibraryIndexTests: XCTestCase {
    private func item(_ name: String) -> Xipixiaojuchang.LibraryItem {
        Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, name: name, projectKey: "library-index")
    }

    func testLookupsStayCorrectAcrossAddRemoveReorderAndInPlaceEdits() {
        let app = AppModel()
        let before = app.library
        defer { app.library = before }
        let a = item("角色-甲"), b = item("角色-乙"), c = item("角色-丙")
        app.library = before + [a, b, c]
        XCTAssertEqual(app.libraryItem(b.id)?.name, "角色-乙")
        XCTAssertNil(app.libraryItem(UUID()))

        // 加一条
        let d = item("角色-丁")
        app.library.append(d)
        XCTAssertEqual(app.libraryItem(d.id)?.name, "角色-丁")
        // 删掉一条：后面的下标都变了
        app.library.removeAll { $0.id == a.id }
        XCTAssertNil(app.libraryItem(a.id), "删掉的查不到")
        XCTAssertEqual(app.libraryItem(c.id)?.name, "角色-丙")
        // 条数不变、顺序整体换了
        app.library.reverse()
        XCTAssertEqual(app.libraryItem(b.id)?.name, "角色-乙")
        XCTAssertEqual(app.libraryItem(d.id)?.name, "角色-丁")
        // 原地改某一条：查到的是改过的
        if let i = app.library.firstIndex(where: { $0.id == c.id }) { app.library[i].name = "角色-丙（改名）" }
        XCTAssertEqual(app.libraryItem(c.id)?.name, "角色-丙（改名）")
        // 同样条数下整个换成另一批
        app.library = before + [item("角色-戊"), item("角色-己"), item("角色-庚")]
        XCTAssertNil(app.libraryItem(c.id))
    }
}
