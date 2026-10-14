#!/usr/bin/env python3
"""Makes a bundled coin logo what TokenLogo draws well in both appearances: a transparent square holding the coin's disc,
centred and filling it. ios/DyorKit's TokenLogoAssetTests checks every file in ios/DyorHQ/Resources/TokenLogos.

A logo rasterized from the token list's SVG can come out on an opaque square plate, drawn small in one corner; TokenLogo
clips the square to a circle, so the plate shows as a crescent beside the coin (white on a dark card). Per file:
  1. The plate is the colour of the top-left corner. A file whose four corners are already transparent is left alone,
     so running this again changes nothing.
  2. The plate is flood-filled from each corner that has its colour, with a tolerance of 8 (the summed channel
     difference), and made transparent.
  3. What the plate touched is mended, as the coin's shape allows:
     - A round coin (the outermost pixels left lie on one circle) gets back any of its own pixels inside that circle
       the fill took: a rim as pale as the plate, such as the lit top of USDe's silver bevel. The circle is fitted to the
       coin's other sides, leaving out the stretch that was eaten.
     - Any other coin (WETH, drawn in perspective) has the pixels within 2 px of the removed plate un-blended from it:
       each gets the least coverage, and the colour, that drawn over the plate would give the pixel. The grey
       anti-aliasing between WETH's black outline and the white plate so becomes a black edge fading out, not a
       light-grey fringe on a dark card.
  4. The coin is cropped to its box and centred on a square.
  5. A circular mask inset 1 px drops the rim pixels that were blended with the plate.
  6. The square is resampled (Lanczos) to the file's own canvas size, and the same circle, anti-aliased, clears anything
     the resampling spread outside it.
The file keeps its exact name (a device looks logos up by exact case), and is written as RGBA. The shipped files are
this script's output from the plated files build 16 shipped, which the parent of the commit that added this script has:
  git show "$(git log --format=%h --diff-filter=A -- scripts/dev/normalize-token-logos.py)^:ios/DyorHQ/Resources/TokenLogos/logo-WETH.png"

Usage: python3 scripts/dev/normalize-token-logos.py [--dry-run] [logo-XYZ.png ...]
       With no file, every logo-*.png in ios/DyorHQ/Resources/TokenLogos. Needs Pillow."""
import glob, math, os, sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter

LOGOS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'ios', 'DyorHQ', 'Resources', 'TokenLogos')
TOLERANCE = 8
SUPERSAMPLE = 4
FRINGE = 2

def circle(side, inset):
    """An anti-aliased disc mask of `side` px, its edge `inset` px in from the square's."""
    big = side * SUPERSAMPLE
    mask = Image.new('L', (big, big), 0)
    ImageDraw.Draw(mask).ellipse([inset * SUPERSAMPLE, inset * SUPERSAMPLE, big - 1 - inset * SUPERSAMPLE, big - 1 - inset * SUPERSAMPLE], fill=255)
    return mask.resize((side, side), Image.LANCZOS)

def fit(points):
    """The least-squares circle (cx, cy, r) through `points` (Kåsa's fit)."""
    sums = [0.0] * 8 # x², xy, y², x, y, n, xz, yz, then z, with z = x² + y²
    sz = 0.0
    for x, y in points:
        z = x * x + y * y
        for i, value in enumerate((x * x, x * y, y * y, x, y, 1, x * z, y * z)):
            sums[i] += value
        sz += z
    sxx, sxy, syy, sx, sy, n, sxz, syz = sums
    matrix = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
    rhs = [-sxz, -syz, -sz]
    def det(m):
        return (m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]))
    whole = det(matrix)
    d, e, f = (det([[rhs[r] if c == i else matrix[r][c] for c in range(3)] for r in range(3)]) / whole for i in range(3))
    cx, cy = -d / 2, -e / 2
    return cx, cy, math.sqrt(max(cx * cx + cy * cy - f, 0))

def round_coin(kept):
    """The circle through the centres of the coin's outermost pixels when the coin is round, else None. Where the fill
    ate a pale rim, the outermost pixels left sit inside the circle; they are dropped and the circle refitted to the
    rest, until it settles. The coin is round when at least 90% of its outermost pixels lie within 1.5 px of the circle
    and at most 1% outside it (WETH: 29% on it)."""
    width, height = kept.size
    k = kept.load()
    points = [(x + 0.5, y + 0.5) for y in range(height) for x in range(width) if k[x, y]
              and any(0 <= x + dx < width and 0 <= y + dy < height and not k[x + dx, y + dy]
                      for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))]
    if len(points) < 32:
        return None
    used = points
    for _ in range(20):
        cx, cy, r = fit(used)
        rest = [p for p in points if math.hypot(p[0] - cx, p[1] - cy) - r > -1]
        if len(rest) == len(used) or len(rest) < 32:
            break
        used = rest
    residuals = [math.hypot(x - cx, y - cy) - r for x, y in points]
    on = sum(abs(d) <= 1.5 for d in residuals) / len(points)
    outside = sum(d > 1.5 for d in residuals) / len(points)
    return (cx, cy, r) if on >= 0.9 and outside <= 0.01 else None

def unblend(pixel, plate):
    """The least coverage, and the colour, that drawn over `plate` give `pixel` (colour to alpha)."""
    coverage = 0.0
    for p, b in zip(pixel[:3], plate[:3]):
        if p > b:
            coverage = max(coverage, (p - b) / (255 - b))
        elif p < b:
            coverage = max(coverage, (b - p) / b)
    if coverage == 0:
        return (0, 0, 0, 0)
    colour = tuple(max(0, min(255, round(b + (p - b) / coverage))) for p, b in zip(pixel[:3], plate[:3]))
    return colour + (round(coverage * pixel[3]),)

def normalize(path):
    """The normalized image and a line describing it, or None and the reason it is left alone."""
    image = Image.open(path).convert('RGBA')
    width, height = image.size
    corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
    if all(image.getpixel(c)[3] == 0 for c in corners):
        return None, 'already transparent, left alone'
    plate = image.getpixel((0, 0))
    marked = image.copy()
    marker = (255, 0, 255, 0)
    for corner in corners:
        pixel = marked.getpixel(corner)
        if pixel != marker and sum(abs(a - b) for a, b in zip(pixel, plate)) <= TOLERANCE:
            ImageDraw.floodfill(marked, corner, marker, thresh=TOLERANCE)
    kept = marked.getchannel('A').point(lambda a: 255 if a else 0)
    coin = image.copy()
    disc = round_coin(kept)
    if disc is not None:
        # The coin's own pixels inside its circle (their centres inside the ring of outermost pixels) come back.
        cx, cy, r = disc
        k, restored = kept.load(), 0
        for y in range(height):
            for x in range(width):
                if not k[x, y] and math.hypot(x + 0.5 - cx, y + 0.5 - cy) <= r - 0.5:
                    k[x, y] = 255
                    restored += 1
        mended = f'round, {restored} rim px kept'
    else:
        near = ImageChops.invert(kept).filter(ImageFilter.MaxFilter(2 * FRINGE + 1))
        n, k, c = near.load(), kept.load(), coin.load()
        unblended = 0
        for y in range(height):
            for x in range(width):
                if k[x, y] and n[x, y]:
                    c[x, y] = unblend(c[x, y], plate)
                    unblended += 1
        mended = f'not round, {unblended} px next to the plate un-blended'
    coin.putalpha(ImageChops.multiply(coin.getchannel('A'), kept))
    box = coin.getchannel('A').getbbox()
    if box is None:
        raise SystemExit(f'{os.path.basename(path)}: nothing is left once the plate is removed')
    x0, y0, x1, y1 = box
    side = max(x1 - x0, y1 - y0)
    left, top = round((x0 + x1 - side) / 2), round((y0 + y1 - side) / 2)
    square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    square.alpha_composite(coin.crop((left, top, left + side, top + side)))
    square.putalpha(ImageChops.multiply(square.getchannel('A'), circle(side, 1)))
    canvas = max(width, height)
    out = square.resize((canvas, canvas), Image.LANCZOS)
    out.putalpha(ImageChops.multiply(out.getchannel('A'), circle(canvas, 0)))
    return out, f'plate {plate[:3]} removed ({mended}); coin {side} px at ({x0},{y0}) centred on {canvas}x{canvas}'

def main(args):
    dry = '--dry-run' in args
    paths = [a for a in args if a != '--dry-run'] or sorted(glob.glob(os.path.join(LOGOS, 'logo-*.png')))
    for path in paths:
        image, note = normalize(path)
        if image is not None and not dry:
            image.save(path, optimize=True)
        print(f'{os.path.basename(path)}: {note}')

if __name__ == '__main__':
    main(sys.argv[1:])
