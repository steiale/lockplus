import AppKit
// Key the padlock out of the navy 1.x icon (build/appicon.png) as a clean layer for the Icon Composer icon.
// 1. Binary mask: red ≥ T (navy and its near-black contact shadow stay below; the grey lock and white cross are above).
// 2. Fill every enclosed gap except the shackle opening (the component containing the seed point).
// 3. Morphological open (erode r, dilate r) strips the grainy shadow fringe; a small blur gives anti-aliased edges.
// Usage: key-app-mark <in.png> <lock.png> [threshold 16] [open radius 3] [shadow.png]
let args = CommandLine.arguments
let T = Double(args.count > 3 ? args[3] : "16")!, R = Int(args.count > 4 ? args[4] : "2")!
let img = NSImage(contentsOfFile: args[1])!
var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let W = cg.width, H = cg.height, N = W * H, cs = CGColorSpace(name: CGColorSpace.sRGB)!
var buf = [UInt8](repeating: 0, count: N * 4)
let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))   // memory row 0 = top
var m = [Bool](repeating: false, count: N)
for i in 0..<N { m[i] = Double(buf[4*i]) >= T }
// Components of the background; keep only those touching the border or containing the shackle-opening seed.
let seed = 300 * W + 512    // (512, 300 from top; memory row 0 is the top): middle of the shackle opening
var comp = [Int32](repeating: -1, count: N); var cid: Int32 = 0; var stack = [Int]()
for s in 0..<N where !m[s] && comp[s] < 0 {
  var members = [Int](); var keep = false
  stack.append(s); comp[s] = cid
  while let p = stack.popLast() {
    members.append(p); let x = p % W, y = p / W
    if x == 0 || y == 0 || x == W - 1 || y == H - 1 || p == seed { keep = true }
    if x > 0, !m[p-1], comp[p-1] < 0 { comp[p-1] = cid; stack.append(p-1) }
    if x < W-1, !m[p+1], comp[p+1] < 0 { comp[p+1] = cid; stack.append(p+1) }
    if y > 0, !m[p-W], comp[p-W] < 0 { comp[p-W] = cid; stack.append(p-W) }
    if y < H-1, !m[p+W], comp[p+W] < 0 { comp[p+W] = cid; stack.append(p+W) }
  }
  if !keep { for p in members { m[p] = true } }
  cid += 1
}
func morph(_ a: [Bool], _ r: Int, erode: Bool) -> [Bool] {   // separable square structuring element
  var t = a
  for y in 0..<H { for x in 0..<W { var v = erode; for dx in -r...r { let xx = x + dx; let b = (xx < 0 || xx >= W) ? false : a[y*W+xx]; if erode { v = v && b } else { v = v || b } }; t[y*W+x] = v } }
  var o = t
  for y in 0..<H { for x in 0..<W { var v = erode; for dy in -r...r { let yy = y + dy; let b = (yy < 0 || yy >= H) ? false : t[yy*W+x]; if erode { v = v && b } else { v = v || b } }; o[y*W+x] = v } }
  return o
}
m = morph(morph(m, R, erode: true), R, erode: false)
var alpha = [Double](repeating: 0, count: N)    // 5×5 box blur of the mask
for y in 0..<H { for x in 0..<W { var s = 0.0, n = 0.0
  for dy in -2...2 { for dx in -2...2 { let xx = x+dx, yy = y+dy; if xx >= 0, yy >= 0, xx < W, yy < H { s += m[yy*W+xx] ? 1 : 0; n += 1 } } }
  alpha[y*W+x] = s / n } }
var out = [UInt8](repeating: 0, count: N * 4)
for i in 0..<N {
  let a = alpha[i]; if a == 0 { continue }
  let r = Double(buf[4*i]); var g = Double(buf[4*i+1]), b = Double(buf[4*i+2])
  if a < 1 || r < 30 { g = min(g, r * 1.06 + 2); b = min(b, r * 1.06 + 2) }   // no navy cast on dark/edge pixels
  out[4*i] = UInt8(r * a); out[4*i+1] = UInt8(g * a); out[4*i+2] = UInt8(b * a); out[4*i+3] = UInt8((a * 255).rounded())
}
// 4. Shadow layer (optional 5th argument): black, alpha = how much darker than the navy each background pixel is, so the
//    baked-in drop shadow survives on any fill. Lock pixels are excluded (the lock layer covers them).
if args.count > 5 {
//    Darkening under 10 % is the navy's texture and vignette, not shadow; the result is capped and blurred so the
//    near-black contact shadow reads as soft light on the off-white fill instead of an outline.
  // Reference navy: median blue of the outermost 8 px ring (in this buffer's colour space, not a hard-coded value).
  var ring = [Double]()
  for y in 0..<H { for x in 0..<W where x < 8 || y < 8 || x >= W - 8 || y >= H - 8 { ring.append(Double(buf[4*(y*W+x)+2])) } }
  ring.sort(); let bgB = ring[ring.count / 2]
  let floor = 0.10, cap = 0.55, blurR = 6
  var d = [Double](repeating: 0, count: N)
  for i in 0..<N where alpha[i] < 1 {
    let dark = max(0, 1 - Double(buf[4*i+2]) / bgB)
    d[i] = min(cap, max(0, (dark - floor) / (1 - floor)))
  }
  for _ in 0..<2 {   // two separable box passes ≈ a soft Gaussian
    var t = d
    for y in 0..<H { var acc = 0.0; for x in -blurR..<W + blurR {
      if x + blurR < W { acc += d[y*W + x + blurR] }; if x - blurR - 1 >= 0 { acc -= d[y*W + x - blurR - 1] }
      if x >= 0 && x < W { t[y*W + x] = acc / Double(2 * blurR + 1) } } }
    for x in 0..<W { var acc = 0.0; for y in -blurR..<H + blurR {
      if y + blurR < H { acc += t[(y + blurR)*W + x] }; if y - blurR - 1 >= 0 { acc -= t[(y - blurR - 1)*W + x] }
      if y >= 0 && y < H { d[y*W + x] = acc / Double(2 * blurR + 1) } } }
  }
  var sh = [UInt8](repeating: 0, count: N * 4)
  for i in 0..<N { sh[4*i+3] = UInt8((min(1, d[i]) * 255).rounded()) }
  let sctx = CGContext(data: &sh, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  try! NSBitmapImageRep(cgImage: sctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[5]))
}
let octx = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
try! NSBitmapImageRep(cgImage: octx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
