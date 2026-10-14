"""从 imagegen 硬币与投币箱原稿导出静态预览和单次抛币 GIF。"""

import math

from PIL import Image, ImageChops, ImageDraw, ImageEnhance


SIZE = (360, 260)
FRAMES = 24
FRAME_MS = 40
SCALE = 2
BOX_POSITION = (167, 78)
BOX_WIDTH = 166
SLOT_POSITION = (0.522, 0.174)
SLOT_SLOPE = 0.16


def load_sprite(path):
    with Image.open(path) as source:
        image = source.convert('RGBA')
        bounds = image.getchannel('A').point(lambda a: 255 if a > 8 else 0).getbbox()
        return image.crop(bounds)


def draw_coin(image, sprite, center, extent, turn=0, tilt=0):
    # 翻转时保留一道金色币缘，避免边缘朝向观察者时突然消失。
    width = max(6, round(extent * abs(math.cos(turn))))
    coin = sprite.resize((width * SCALE, round(extent * SCALE)), Image.Resampling.LANCZOS)
    coin = coin.rotate(tilt, resample=Image.Resampling.BICUBIC, expand=True)
    image.alpha_composite(coin, (
        round(center[0] * SCALE - coin.width / 2),
        round(center[1] * SCALE - coin.height / 2),
    ))


def base(box_sprite, empty=False, bounce=0):
    image = Image.new('RGBA', (SIZE[0] * SCALE, SIZE[1] * SCALE))
    draw = ImageDraw.Draw(image)
    def box(rect):
        return tuple(round(v * SCALE) for v in rect)
    draw.ellipse(box((165, 239, 335, 253)), fill=(27, 35, 49, 55))
    image.alpha_composite(box_sprite, (
        BOX_POSITION[0] * SCALE, round((BOX_POSITION[1] + bounce) * SCALE),
    ))
    if empty:
        draw.ellipse(box((66, 125, 124, 184)), outline='#8392A8', width=2 * SCALE)
        draw.line(box((80, 155, 110, 155)), fill='#BFC9D6', width=3 * SCALE)
    return image


def idle(sprite, box_sprite, count):
    image = base(box_sprite)
    if count == 1:
        draw_coin(image, sprite, (94, 166), 82, tilt=-8)
    else:
        draw_coin(image, sprite, (75, 171), 76, tilt=12)
        draw_coin(image, sprite, (112, 147), 82, tilt=-9)
    return image.resize(SIZE, Image.Resampling.LANCZOS)


def toss_frame(sprite, box_sprite, count, frame):
    time = frame * FRAME_MS / 1000
    slot = (
        BOX_POSITION[0] + box_sprite.width / SCALE * SLOT_POSITION[0],
        BOX_POSITION[1] + box_sprite.height / SCALE * SLOT_POSITION[1],
    )
    bounce = 0
    for coin in range(count):
        impact = (time - 0.80 - 0.10 * coin) / 0.08
        if 0 < impact < 1 and frame != FRAMES - 1:
            bounce += 2 * math.sin(math.pi * impact)
    image = base(box_sprite, bounce=bounce)
    for coin in range(count):
        # 从箱外起抛，沿弧线落进顶盖槽口；双币错开 100ms 出手。
        elapsed = time - 0.08 - 0.10 * coin
        progress = max(0, min(1, elapsed / 0.56))
        insertion = max(0, (elapsed - 0.56) / 0.16)
        start = (94, 166) if count == 1 else [(75, 171), (112, 147)][coin]
        extent = (82 if count == 1 or coin == 1 else 76) * (1 - 0.25 * progress)
        if insertion >= 1:
            continue
        control = (174 + 12 * coin, -18)
        x = (1 - progress) ** 2 * start[0] + 2 * (1 - progress) * progress * control[0] + progress ** 2 * slot[0]
        y = (1 - progress) ** 2 * start[1] + 2 * (1 - progress) * progress * control[1] + progress ** 2 * (slot[1] - 12)
        if insertion > 0:
            y += insertion * (20 + extent / 2)
        layer = Image.new('RGBA', image.size)
        draw_coin(layer, sprite, (x, y), extent,
                  turn=progress * math.tau * 1.25, tilt=-8 + 8 * progress)
        if progress > 0.8:
            # 槽口前沿遮住硬币下半部，随下落逐步吞入箱内。
            lip = slot[1] + bounce + 6
            mask = Image.new('L', image.size)
            ImageDraw.Draw(mask).polygon([
                (0, 0), (image.width, 0),
                (image.width, round((lip + SLOT_SLOPE * (SIZE[0] - slot[0])) * SCALE)),
                (0, round((lip - SLOT_SLOPE * slot[0]) * SCALE)),
            ], fill=255)
            layer.putalpha(ImageChops.multiply(layer.getchannel('A'), mask))
        image.alpha_composite(layer)
    return image.resize(SIZE, Image.Resampling.LANCZOS)


def export_coin_motion(root, assets, gif_frame, save_image):
    sprite = load_sprite(root / 'tool/artwork/raster/coin.png')
    box_sprite = load_sprite(root / 'tool/artwork/raster/coin-box.png')
    box_sprite = box_sprite.resize((BOX_WIDTH * SCALE, round(BOX_WIDTH * SCALE * box_sprite.height / box_sprite.width)), Image.Resampling.LANCZOS)
    destination = assets / 'paycoins'
    for count, word, preview in [
        (1, 'one', 'ic_22_mario'), (2, 'two', 'ic_22_gun_sister'),
    ]:
        save_image(idle(sprite, box_sprite, count), destination / f'{preview}.png', optimize=True)
        frames = [gif_frame(toss_frame(sprite, box_sprite, count, i)) for i in range(FRAMES)]
        # 省略 loop 扩展：GIF 播放一次，结束后停在落币帧。
        save_image(frames[0], destination / f'coin_toss_{word}.gif', save_all=True,
                       append_images=frames[1:], duration=FRAME_MS,
                       transparency=0, disposal=2, optimize=False)
    empty = ImageEnhance.Color(base(box_sprite, empty=True)).enhance(0.4)
    save_image(empty.resize(SIZE, Image.Resampling.LANCZOS),
               destination / 'ic_22_not_enough_pay.png', optimize=True)
