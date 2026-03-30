"""
TIFF/TIF to PNG Converter
Input  : D:/Coolyeah/Portofolio/live-photo-app/motion_photo_app_antigravity/assets/lutstif
Output : D:/Coolyeah/Portofolio/live-photo-app/motion_photo_app_antigravity/assets/luts
- Color mode : RGB -> sRGB (with embedded ICC profile)
- Bit depth  : 8-bit
- No upscaling or downscaling
"""

from pathlib import Path
from PIL import Image, ImageCms


def convert_tiff_to_png(input_folder: str, output_folder: str) -> None:
    input_path  = Path(input_folder)
    output_path = Path(output_folder)

    # Validate input folder
    if not input_path.exists():
        print(f"[ERROR] Input folder not found: {input_path.resolve()}")
        return

    # Create output folder if it doesn't exist
    output_path.mkdir(parents=True, exist_ok=True)

    # Find all tiff/tif files — case-insensitive, no duplicates
    tiff_files = list({
        f for f in input_path.iterdir()
        if f.suffix.lower() in (".tif", ".tiff")
    })

    if not tiff_files:
        print(f"[INFO] No TIFF/TIF files found in: {input_path.resolve()}")
        return

    print(f"[INFO] Found {len(tiff_files)} TIFF file(s) in '{input_path.resolve()}'")
    print(f"[INFO] Output folder: '{output_path.resolve()}'")
    print("-" * 55)

    # Build sRGB ICC profile once
    srgb_profile = ImageCms.createProfile("sRGB")

    success_count = 0
    fail_count    = 0

    for tiff_file in tiff_files:
        output_file = output_path / tiff_file.with_suffix(".png").name

        try:
            with Image.open(tiff_file) as img:
                # --- Ensure 8-bit ---
                if img.mode in ("I", "I;16", "I;16B"):
                    # 16-bit grayscale -> 8-bit
                    img = img.point(lambda x: x * (1 / 256)).convert("L")
                elif img.mode == "RGBA":
                    img = img.convert("RGBA")  # keep alpha, already 8-bit RGBA
                else:
                    img = img.convert("RGB")   # force RGB 8-bit

                # --- Convert to sRGB with embedded ICC profile ---
                if img.mode == "RGBA":
                    # Split alpha, convert RGB part to sRGB, re-merge
                    r, g, b, a = img.split()
                    rgb = Image.merge("RGB", (r, g, b))
                    srgb_img = ImageCms.profileToProfile(
                        rgb,
                        ImageCms.createProfile("sRGB"),
                        srgb_profile,
                        outputMode="RGB"
                    )
                    srgb_img.putalpha(a)
                else:
                    srgb_img = ImageCms.profileToProfile(
                        img,
                        ImageCms.createProfile("sRGB"),
                        srgb_profile,
                        outputMode="RGB"
                    )

                original_size = srgb_img.size

                # Save PNG with embedded sRGB ICC profile, lossless
                srgb_img.save(
                    output_file,
                    format="PNG",
                    compress_level=0,
                    optimize=False,
                    icc_profile=ImageCms.ImageCmsProfile(srgb_profile).tobytes()
                )

            print(f"  [OK]  {tiff_file.name}")
            print(f"        -> {output_file.name}  |  {original_size[0]}x{original_size[1]}px  |  mode: sRGB 8-bit")
            success_count += 1

        except Exception as e:
            print(f"  [FAIL] {tiff_file.name}: {e}")
            fail_count += 1

    print("-" * 55)
    print(f"[DONE] Converted: {success_count}  |  Failed: {fail_count}")
    print(f"[OUT]  PNG files saved to: {output_path.resolve()}")


if __name__ == "__main__":
    INPUT_FOLDER  = r"D:\Coolyeah\Portofolio\live-photo-app\motion_photo_app_antigravity\assets\lutstif"
    OUTPUT_FOLDER = r"D:\Coolyeah\Portofolio\live-photo-app\motion_photo_app_antigravity\assets\luts"

    convert_tiff_to_png(INPUT_FOLDER, OUTPUT_FOLDER)