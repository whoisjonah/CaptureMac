import Foundation
import Testing
@testable import CaptureMac

struct SignerTests {
    @Test func matchesAWSExample() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let signer = Signer(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
        signer.sign(&request, payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", date: date)

        let authorization = request.value(forHTTPHeaderField: "Authorization")
        #expect(authorization == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func encodesKeysPerSegment() {
        let url = URL(string: "https://acct.r2.cloudflarestorage.com/bucket/my%20clips/a+b.mp4")!
        #expect(Signer.canonicalPath(url) == "/bucket/my%20clips/a%2Bb.mp4")
    }

    @Test func keysUseFolderAndExtension() {
        let key = R2Client.makeKey(for: URL(fileURLWithPath: "/tmp/Clip.MP4"), folder: "/clips/")
        #expect(key.hasPrefix("clips/"))
        #expect(key.hasSuffix(".mp4"))
        #expect(key.count == "clips/".count + 10 + 4)
    }
}
