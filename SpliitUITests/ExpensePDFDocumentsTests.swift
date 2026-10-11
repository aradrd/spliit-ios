import XCTest

/// Attaching a PDF, which reaches the expense as one picture per page — the only kind of document
/// the web app can show.
///
/// The PDF is the one the app draws for itself, two pages of the sample receipt, because the Files
/// picker runs out of process where no test can reach into it. Everything after the file is real:
/// the pages are drawn by the code a picked PDF goes through, and uploaded to the bucket
/// `make e2e-up` brings up, as in `ExpenseDocumentsTests`.
final class ExpensePDFDocumentsTests: SpliitUITestCase {

    @MainActor
    func testEachPageOfAPDFIsAttachedAsADocument() async throws {
        let group = try await api.createGroup(name: "Trip", participants: ["Ana", "Bruno"])
        let app = launchApp(
            recentGroups: SpliitTestAPI.recentGroupsJSON([(group.id, "Trip")]),
            pdfSample: true
        )

        app.staticTexts[AccessibilityID.GroupsList.rowTitle(group.id)].tap()
        app.buttons[AccessibilityID.ExpenseList.emptyAddButton].tap()

        replaceText(in: app.textFields[AccessibilityID.ExpenseForm.titleField], with: "Train")
        replaceText(in: app.textFields[AccessibilityID.ExpenseForm.amountField], with: "120.00")

        let add = app.buttons[AccessibilityID.Documents.addButton]
        scrollUntilHittable(add, in: app)
        assertExists(add, "A new expense should offer to attach a document.")
        add.tap()

        // The pages go up one after the other, so the second tile appearing is what says both
        // have been stored.
        assertExists(
            app.buttons[AccessibilityID.Documents.thumbnail(0)],
            "The first page should appear in the grid once it is stored."
        )
        assertExists(
            app.buttons[AccessibilityID.Documents.thumbnail(1)],
            "The second page should appear in the grid once it is stored."
        )
        XCTAssertFalse(
            app.buttons[AccessibilityID.Documents.thumbnail(2)].exists,
            "A two-page PDF should be two documents."
        )
        capture(app, "expense-pdf-documents")

        app.buttons[AccessibilityID.ExpenseForm.saveButton].tap()
        assertExists(app.staticTexts["Train"], "The expense should save.")

        let expense = try await api.expense(inGroup: group.id, titled: "Train")
        let documents = try XCTUnwrap(
            expense["documents"] as? [[String: Any]], "the expense should carry its documents"
        )
        XCTAssertEqual(documents.count, 2, "Each page should have become a document of its own.")

        for document in documents {
            // Drawn at the cap rather than at the 612 by 792 points the page was laid out in,
            // which is what makes the small print on an e-receipt readable.
            let width = try XCTUnwrap(document["width"] as? Int)
            let height = try XCTUnwrap(document["height"] as? Int)
            XCTAssertGreaterThan(min(width, height), 0)
            XCTAssertEqual(max(width, height), 2048, "A page should be drawn at the full size.")

            let address = try XCTUnwrap(document["url"] as? String)
            let (data, response) = try await URLSession.shared.data(
                from: try XCTUnwrap(URL(string: address))
            )
            XCTAssertEqual(
                (response as? HTTPURLResponse)?.statusCode, 200,
                "Each stored page should be served to anybody who asks for it."
            )
            XCTAssertFalse(data.isEmpty)
        }
    }
}
