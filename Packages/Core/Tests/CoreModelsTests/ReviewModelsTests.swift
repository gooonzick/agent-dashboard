import CoreModels
import Foundation
import Testing

@Suite struct ReviewModelsTests {
    @Test func unknownAndNoneAreTheirOwnStatesAndHaveNothingElse() {
        #expect(ReviewInfo.unknown == ReviewInfo(state: .unknown, number: nil, webURL: nil, headSHA: nil))
        #expect(ReviewInfo.none == ReviewInfo(state: .none, number: nil, webURL: nil, headSHA: nil))
        #expect(ReviewInfo.unknown.state == .unknown)
        #expect(ReviewInfo.none.state == .none)
        #expect(ReviewInfo.unknown != ReviewInfo.none)
    }

    @Test func aStateIsWrittenAsItsName() throws {
        let names: [(ReviewState, String)] = [
            (.open, "open"), (.draft, "draft"), (.merged, "merged"), (.closed, "closed"), (.none, "none"),
            (.unknown, "unknown"),
        ]
        for (state, name) in names {
            #expect(state.rawValue == name)
            #expect(String(decoding: try JSONEncoder().encode(state), as: UTF8.self) == "\"\(name)\"")
        }
    }

    @Test func aReviewSurvivesJSON() throws {
        let info = ReviewInfo(state: .merged, number: 42, webURL: URL(string: "https://g/mr/42"), headSHA: "abc")

        let decoded = try JSONDecoder().decode(ReviewInfo.self, from: try JSONEncoder().encode(info))

        #expect(decoded == info)
        #expect(
            try JSONDecoder().decode(ReviewInfo.self, from: try JSONEncoder().encode(ReviewInfo.unknown)) == .unknown)
    }

    @Test(arguments: ["Merged", "MERGED", "merge", "", "opened", "reopened"])
    func aStateThatIsNotOneOfTheSixIsNotReadAsAnyOfThem(name: String) {
        // A file that was written by another version, or by hand, must not become a state that it does not say.
        let json = Data(#"{"state": "\#(name)"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ReviewInfo.self, from: json) }
    }
}
