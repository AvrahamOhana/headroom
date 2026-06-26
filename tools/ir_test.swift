import Foundation
import Accelerate

// Mirror AmpBlock's block-wise vDSP overlap convolution; compare to a direct reference.
let ir: [Float] = [0.5, 0.3, -0.2, 0.1, 0.05]      // 5-tap IR
let irLen = ir.count
var irRev = (0..<irLen).map { ir[irLen - 1 - $0] }  // reversed → vDSP_conv yields convolution

let N = 23
let input = (0..<N).map { sinf(Float($0) * 0.7) }   // arbitrary signal

// Reference: direct causal convolution  y[m] = Σ_k x[m-k]·ir[k]
var ref = [Float](repeating: 0, count: N)
for m in 0..<N { var s: Float = 0; for k in 0..<irLen where m - k >= 0 { s += input[m-k] * ir[k] }; ref[m] = s }

// Block processing with history (mirror of the real-time path), odd block size on purpose
var hist = [Float](repeating: 0, count: irLen - 1)
var out = [Float](repeating: 0, count: N)
let blk = 6
var off = 0
while off < N {
    let n = min(blk, N - off)
    var scr = hist + Array(input[off..<off+n])               // [hist | block], length (irLen-1)+n
    var bo = [Float](repeating: 0, count: n)
    vDSP_conv(&scr, 1, &irRev, 1, &bo, 1, vDSP_Length(n), vDSP_Length(irLen))
    for j in 0..<n { out[off+j] = bo[j] }
    hist = Array(scr[n..<n + irLen - 1])                      // carry last (irLen-1) inputs
    off += n
}

var maxErr: Float = 0
for i in 0..<N { maxErr = max(maxErr, abs(out[i] - ref[i])) }
for i in 0..<8 { print(String(format: "%2d  ref=%+.4f  out=%+.4f", i, ref[i], out[i])) }
print(String(format: "\nmaxErr = %.2e   %@", maxErr, maxErr < 1e-4 ? "✓ convolution correct (reversal + overlap)" : "✗ MISMATCH"))
