import { readFile } from "node:fs/promises";
import { PNG } from "pngjs";

export interface PreviewOptions {
  /** Longest side of the returned image, in pixels. The scale factor is always an integer. */
  maxSize: number;
  /** Composite onto a gray checkerboard so transparency is visible. */
  checkerboard: boolean;
  /** Draw a 1px line between upscaled pixels when the scale is large. */
  pixelGrid: boolean;
}

export interface FrameLayout {
  frameWidth: number;
  frameHeight: number;
  gap: number;
}

/**
 * Nearest-neighbor upscale of a PNG file; returns base64 PNG and the scale used.
 * With a frame layout, the gutters between frames are painted dark gray.
 */
export async function upscalePng(
  file: string,
  opts: PreviewOptions,
  layout?: FrameLayout,
): Promise<{ base64: string; scale: number; width: number; height: number }> {
  const src = PNG.sync.read(await readFile(file));
  const longest = Math.max(src.width, src.height);
  const scale = Math.max(1, Math.floor(opts.maxSize / longest));
  const w = src.width * scale;
  const h = src.height * scale;
  const out = new PNG({ width: w, height: h });
  // Checker squares cover whole sprite pixels and are at least ~8 screen pixels.
  const cell = Math.ceil(8 / scale) * scale;
  const grid = opts.pixelGrid && scale >= 8;
  const isGutter = (sx: number, sy: number) =>
    layout !== undefined &&
    layout.gap > 0 &&
    (sx % (layout.frameWidth + layout.gap) >= layout.frameWidth || sy % (layout.frameHeight + layout.gap) >= layout.frameHeight);
  for (let y = 0; y < h; y++) {
    const sy = Math.floor(y / scale);
    for (let x = 0; x < w; x++) {
      const sx = Math.floor(x / scale);
      const si = (sy * src.width + sx) * 4;
      const di = (y * w + x) * 4;
      if (isGutter(sx, sy)) {
        out.data[di] = out.data[di + 1] = out.data[di + 2] = 64;
        out.data[di + 3] = 255;
        continue;
      }
      let r = src.data[si], g = src.data[si + 1], b = src.data[si + 2];
      const a = src.data[si + 3] / 255;
      if (opts.checkerboard) {
        const light = (Math.floor(x / cell) + Math.floor(y / cell)) % 2 === 0;
        const bg = light ? 204 : 153;
        r = Math.round(r * a + bg * (1 - a));
        g = Math.round(g * a + bg * (1 - a));
        b = Math.round(b * a + bg * (1 - a));
        out.data[di + 3] = 255;
      } else {
        out.data[di + 3] = src.data[si + 3];
      }
      if (grid && (x % scale === 0 || y % scale === 0)) {
        r = Math.round(r * 0.85);
        g = Math.round(g * 0.85);
        b = Math.round(b * 0.85);
      }
      out.data[di] = r;
      out.data[di + 1] = g;
      out.data[di + 2] = b;
    }
  }
  return { base64: PNG.sync.write(out).toString("base64"), scale, width: w, height: h };
}
