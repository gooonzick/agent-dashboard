import Testing

@testable import Hosting

@Suite struct AccessTokenTests {
    @Test func itShowsAsNothingWhereverAValueIsShown() {
        let secret = "S3CRET-tOkEn_0123456789"
        let token = AccessToken(secret)
        let optional: AccessToken? = token
        var dumped = ""
        dump(token, to: &dumped)

        let shown = [
            token.description, token.debugDescription, "\(token)", String(describing: token),
            String(reflecting: token), String(describing: optional), String(reflecting: optional), dumped,
        ]
        for text in shown {
            #expect(!text.contains(secret), "\(text)")
        }
    }

    @Test func aGoodTokenIsWhatGoesInTheHeaderAndAnEmptyOneIsNone() throws {
        #expect(try AccessToken("glpat-abc_123").headerValue() == "glpat-abc_123")
        #expect(try AccessToken("").headerValue() == nil)
    }

    @Test(arguments: ["tok en", "tok\n", "tok\r\nX-Evil: 1", "tökén", " "])
    func aTokenThatCannotBeAHeaderValueIsRefused(text: String) {
        #expect(throws: ReviewError.unusableToken) { try AccessToken(text).headerValue() }
    }
}
