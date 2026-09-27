"""
Script to split stickers.png into individual sticker PNG images with transparent backgrounds.
Identifies all 18 stickers (including 1 giant cat on the left and 17 stickers across 4 rows on the right),
preserving all detached elements (sweat drops, stars, battery icon, dust cloud, flying papers, ghost soul,
spilled coffee cup & straw) with clean borders and transparent backgrounds.
"""

import os
import sys
import cv2
import numpy as np


def split_stickers(input_image_path: str, output_dir: str):
    if not os.path.exists(input_image_path):
        raise FileNotFoundError(f"Input image not found: {input_image_path}")

    os.makedirs(output_dir, exist_ok=True)

    img = cv2.imread(input_image_path, cv2.IMREAD_UNCHANGED)
    if img is None:
        raise ValueError(f"Could not load image: {input_image_path}")

    h, w, c = img.shape
    if c != 4:
        raise ValueError(f"Image must have an alpha channel (4 channels), got {c}")

    alpha = img[:, :, 3]
    binary = (alpha > 10).astype(np.uint8)

    num_labels, labels, stats, centroids = cv2.connectedComponentsWithStats(binary, connectivity=8)

    # 18 sticker definitions by known interior point (seed point)
    seed_points = [
        # 01 Giant thumbs up
        ("01_giant_thumbs_up", 250, 450),
        # Row 1
        ("02_derp_tongue", 730, 110),
        ("03_confused_question", 980, 110),
        ("04_happy_laugh", 1210, 110),
        ("05_gamer_controller", 1420, 110),
        # Row 2
        ("06_sneaky_drool", 720, 320),
        ("07_cool_sunglasses", 930, 320),
        ("08_peeking_wall", 1090, 320),
        ("09_exhausted_low_battery", 1280, 370),
        ("10_dizzy_spiral", 1440, 320),
        # Row 3
        ("11_basketball", 650, 560),
        ("12_studying_laptop", 910, 580),
        ("13_eating_ramen", 1170, 570),
        ("14_running_fast", 1430, 560),
        # Row 4
        ("15_jumping_excited", 620, 820),
        ("16_lost_map", 840, 850),
        ("17_collapsed_spilled_coffee", 1090, 900),
        ("18_peace_sign_friends", 1380, 840),
    ]

    sticker_names = [s[0] for s in seed_points]
    sticker_masks = [np.zeros((h, w), dtype=bool) for _ in range(18)]

    # Assign main bodies 0..15 (stickers 1 to 16)
    main_labels = [labels[sy, sx] for _, sx, sy in seed_points]
    for s_idx in range(16):
        lbl = main_labels[s_idx]
        sticker_masks[s_idx] |= (labels == lbl)

    def is_sticker_17_body(x, y):
        """
        Classifies pixels in the shared connected component (component 80)
        between Sticker 17 (collapsed cat, coffee cup, straw, floor puddle)
        and Sticker 18 (peace sign cat, hoodie, sneakers, left & right grey buddies).
        """
        if x < 1220:
            return True
        if x <= 1245:
            return y >= 879
        if x <= 1255:
            return y >= 889
        if x <= 1265:
            return y >= 894
        if x <= 1283:
            return y >= 903
        return y >= 950 and x <= 1286

    # Partition shared component between sticker 17 and sticker 18
    comp80_lbl = labels[900, 1090]
    c80_ys, c80_xs = np.where(labels == comp80_lbl)
    for y, x in zip(c80_ys, c80_xs):
        if is_sticker_17_body(x, y):
            sticker_masks[16][y, x] = True
        else:
            sticker_masks[17][y, x] = True

    # Assign all other satellite components (dust cloud, stars, sweat drops, papers, battery, soul)
    assigned_comps = set(main_labels[:16]) | {comp80_lbl}
    for comp_id in range(1, num_labels):
        if comp_id in assigned_comps:
            continue
        cx, cy = centroids[comp_id]

        # 1. Question mark curve & dot -> Sticker 03
        if 840 <= cx <= 890 and cy < 90:
            target = 2
        # 2. Battery icon -> Sticker 09
        elif 1240 <= cx <= 1340 and 240 <= cy <= 300:
            target = 8
        # 3. Flying papers for studying cat -> Sticker 12
        elif (780 <= cx <= 850 and 460 <= cy <= 520) or (990 <= cx <= 1040 and 490 <= cy <= 540):
            target = 11
        # 4. Dust cloud for running cat -> Sticker 14
        elif 1300 <= cx <= 1390 and 600 <= cy <= 680:
            target = 13
        # 5. Stars and lightning on right of jumping cat -> Sticker 15
        elif 700 <= cx <= 760 and 750 <= cy <= 860:
            target = 14
        # 6. Sweat drops for map cat -> Sticker 16
        elif 940 <= cx <= 965 and 740 <= cy <= 830:
            target = 15
        # 7. Ghost soul -> Sticker 17
        elif 1080 <= cx <= 1180 and 700 <= cy <= 830:
            target = 16
        # 8. Floor coffee drip -> Sticker 17
        elif 1220 <= cx <= 1260 and cy >= 950:
            target = 16
        # 9. Sparks & star for peace cat -> Sticker 18
        elif cx >= 1180 and cy >= 670:
            target = 17
        else:
            # Fallback: Distance to bounding box of main bodies 0..15
            min_dist = float("inf")
            target = 0
            for idx in range(16):
                m_lbl = main_labels[idx]
                mb_x, mb_y, mb_w, mb_h = stats[m_lbl][:4]
                dx = max(0, mb_x - cx, cx - (mb_x + mb_w))
                dy = max(0, mb_y - cy, cy - (mb_y + mb_h))
                dist = np.hypot(dx, dy)
                if dist < min_dist:
                    min_dist = dist
                    target = idx

        sticker_masks[target] |= (labels == comp_id)

    # Step 3: Crop each sticker tightly with 8px padding and save
    padding = 8
    saved_files = []

    for s_idx, name in enumerate(sticker_names):
        s_mask = sticker_masks[s_idx]
        sticker_rgba = np.zeros_like(img)
        sticker_rgba[s_mask] = img[s_mask]

        ys, xs = np.where(sticker_rgba[:, :, 3] > 10)
        if len(ys) == 0:
            print(f"Warning: sticker '{name}' has no pixels!")
            continue

        y1 = max(0, min(ys) - padding)
        y2 = min(h, max(ys) + 1 + padding)
        x1 = max(0, min(xs) - padding)
        x2 = min(w, max(xs) + 1 + padding)

        cropped = sticker_rgba[y1:y2, x1:x2]
        file_name = f"{name}.png"
        out_file_path = os.path.join(output_dir, file_name)
        cv2.imwrite(out_file_path, cropped)

        crop_w, crop_h = cropped.shape[1], cropped.shape[0]
        saved_files.append((file_name, crop_w, crop_h, out_file_path))
        print(f"[{s_idx+1:02d}/18] Saved {file_name:<32} ({crop_w}x{crop_h} px)")

    print(f"\nSuccessfully generated {len(saved_files)} stickers in: {output_dir}")
    return saved_files


if __name__ == "__main__":
    current_dir = os.path.dirname(os.path.abspath(__file__))
    input_file = os.path.join(current_dir, "stickers.png")
    output_folder = os.path.join(current_dir, "stickers")

    if len(sys.argv) > 1:
        input_file = sys.argv[1]
    if len(sys.argv) > 2:
        output_folder = sys.argv[2]

    print(f"Input image: {input_file}")
    print(f"Output directory: {output_folder}")
    split_stickers(input_file, output_folder)
