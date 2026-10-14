"""从 imagegen 硬币原稿导出静态预览和单次抛币 GIF。"""

import math

from PIL import Image, ImageDraw, ImageEnhance


SIZE = (360, 260)
FRAMES = 24
FRAME_MS = 40
SCALE = 2


def coin_sprite(path):
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


def base(empty=False):
    image = Image.new('RGBA', (SIZE[0] * SCALE, SIZE[1] * SCALE))
    draw = ImageDraw.Draw(image)
    def box(rect):
        return tuple(round(v * SCALE) for v in rect)
    draw.ellipse(box((100, 204, 273, 224)), fill=(27, 35, 49, 65))
    draw.rounded_rectangle(box((108, 201, 268, 213)), radius=6 * SCALE, fill='#62768E')
    draw.rounded_rectangle(box((130, 201, 247, 206)), radius=2 * SCALE, fill='#29374B')
    draw.line(box((139, 202, 239, 202)), fill='#9EADC0', width=SCALE)
    if empty:
        draw.ellipse(box((155, 96, 213, 155)), outline='#8392A8', width=2 * SCALE)
        draw.line(box((169, 126, 199, 126)), fill='#BFC9D6', width=3 * SCALE)
    return image


def idle(sprite, count):
    image = base()
    if count == 1:
        draw_coin(image, sprite, (177, 134), 114, tilt=-8)
    else:
        draw_coin(image, sprite, (151, 144), 104, tilt=12)
        draw_coin(image, sprite, (204, 123), 114, tilt=-9)
    return image.resize(SIZE, Image.Resampling.LANCZOS)


def toss_frame(sprite, count, frame):
    image = base()
    t = frame / (FRAMES - 1)
    for coin in range(count):
        # 双币共用轨迹，第二枚稍晚起飞且弧线略偏右。
        delay = 0.10 * coin
        progress = max(0, (t - 0.09 - delay) / 0.69)
        start = (177, 134) if count == 1 else [(151, 144), (204, 123)][coin]
        extent = 114 if count == 1 or coin == 1 else 104
        if progress >= 1:
            continue
        x = start[0] + (224 - start[0]) * progress + 19 * math.sin(math.pi * progress)
        y = start[1] + (201 - start[1]) * progress - 100 * math.sin(math.pi * progress)
        if progress > 0:
            draw = ImageDraw.Draw(image)
            trail = []
            for step in range(6):
                q = max(0, progress - step * 0.018)
                trail.append((
                    round((start[0] + (224 - start[0]) * q + 19 * math.sin(math.pi * q)) * SCALE),
                    round((start[1] + (201 - start[1]) * q - 100 * math.sin(math.pi * q)) * SCALE),
                ))
            draw.line(trail, fill=(224, 204, 166, 90), width=2 * SCALE)
        draw_coin(image, sprite, (x, y), extent * (1 - 0.80 * progress ** 3),
                  turn=progress * math.tau * 1.5, tilt=-8 + 24 * progress)
    if t >= 0.79:
        ring = min(1, (t - 0.79) / 0.21)
        draw = ImageDraw.Draw(image)
        radius = 12 + 24 * ring
        draw.ellipse((
            round((224 - radius) * SCALE), round((199 - radius * 0.24) * SCALE),
            round((224 + radius) * SCALE), round((199 + radius * 0.24) * SCALE),
        ), outline=(227, 204, 163, round(200 * (1 - ring))), width=2 * SCALE)
    return image.resize(SIZE, Image.Resampling.LANCZOS)


def export_coin_motion(root, assets, gif_frame, save_image):
    sprite = coin_sprite(root / 'tool/artwork/raster/coin.png')
    destination = assets / 'paycoins'
    for count, word, preview in [
        (1, 'one', 'ic_22_mario'), (2, 'two', 'ic_22_gun_sister'),
    ]:
        save_image(idle(sprite, count), destination / f'{preview}.png', optimize=True)
        frames = [gif_frame(toss_frame(sprite, count, i)) for i in range(FRAMES)]
        # 省略 loop 扩展：GIF 播放一次，结束后停在落币帧。
        save_image(frames[0], destination / f'coin_toss_{word}.gif', save_all=True,
                       append_images=frames[1:], duration=FRAME_MS,
                       transparency=0, disposal=2, optimize=False)
    empty = ImageEnhance.Color(base(empty=True)).enhance(0.4)
    save_image(empty.resize(SIZE, Image.Resampling.LANCZOS),
               destination / 'ic_22_not_enough_pay.png', optimize=True)
