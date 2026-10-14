# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools==4.67.0", "skia-pathops==0.9.2"]
# ///
"""从同目录 SVG 和 manifest.json 生成图标字体及 Dart 定义。"""

import argparse
import json
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

import pathops
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import SVGPath


SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parents[2]
SVG_NAMESPACE = 'http://www.w3.org/2000/svg'


def outline_svg(source):
    root = ET.parse(source).getroot()
    if root.get('viewBox') != '0 0 24 24':
        raise ValueError(f'{source}: expected a 24 x 24 viewBox')
    outline = pathops.Path()
    for element in root:
        if element.tag.rsplit('}', 1)[-1] not in {'path', 'rect', 'circle'}:
            raise ValueError(f'{source}: unsupported geometry {element.tag}')
        if element.get('transform'):
            raise ValueError(f'{source}: use explicit geometry instead of transforms')
        shape = pathops.Path()
        svg = ET.Element(f'{{{SVG_NAMESPACE}}}svg')
        svg.append(element)
        SVGPath.fromstring(ET.tostring(svg)).draw(shape.getPen())

        # 先按每个元素的填充规则展开，再合并；保留实心图标内的镂空。
        fill = element.get('fill', root.get('fill', 'black'))
        if fill != 'none':
            filled = pathops.Path(shape)
            if element.get('fill-rule', root.get('fill-rule')) == 'evenodd':
                filled.fillType = pathops.FillType.EVEN_ODD
            filled = pathops.simplify(filled)
            outline = pathops.op(outline, filled, pathops.PathOp.UNION)

        stroke = element.get('stroke', root.get('stroke', 'none'))
        if stroke != 'none':
            cap = element.get('stroke-linecap', root.get('stroke-linecap'))
            join = element.get('stroke-linejoin', root.get('stroke-linejoin'))
            if cap != 'round' or join != 'round':
                raise ValueError(f'{source}: expected round caps and joins')
            shape.stroke(
                float(element.get('stroke-width', root.get('stroke-width', '1'))),
                pathops.LineCap.ROUND_CAP,
                pathops.LineJoin.ROUND_JOIN,
                4,
            )
            shape.convertConicsToQuads(0.01)
            outline = pathops.op(outline, shape, pathops.PathOp.UNION)
    return pathops.simplify(outline, clockwise=True)


def build(manifest, output):
    units = manifest['units_per_em']
    scale = units / 24
    entries = manifest['icons']
    codepoints = [int(icon['codepoint'], 16) for icon in entries]
    names = [icon['name'] for icon in entries]
    if len(set(codepoints)) != len(entries) or len(set(names)) != len(entries):
        raise ValueError('Icon names and codepoints must be unique')
    if any(not 0xE000 <= value <= 0xF8FF for value in codepoints):
        raise ValueError('Icon codepoints must use the Unicode private-use area')
    svg_sources = {icon['source'] for icon in entries}
    if svg_sources != {source.name for source in SOURCE.glob('*.svg')}:
        raise ValueError('SVG sources and manifest entries must match')

    glyphs = {'.notdef': TTGlyphPen(None).glyph()}
    metrics = {'.notdef': (units, 0)}
    for icon in entries:
        path = outline_svg(SOURCE / icon['source'])
        pen = TTGlyphPen(None)
        # SVG 坐标向下，字体坐标向上；保持整套图标相同的留白和基线。
        path.draw(TransformPen(Cu2QuPen(pen, max_err=0.5, reverse_direction=True),
                               (scale, 0, 0, -scale, 0, units)))
        glyph = pen.glyph()
        glyph.recalcBounds(None)
        glyphs[icon['name']] = glyph
        metrics[icon['name']] = (units, glyph.xMin)

    font = FontBuilder(units, isTTF=True)
    font.setupGlyphOrder(['.notdef', *names])
    font.setupCharacterMap(dict(zip(codepoints, names)))
    font.setupGlyf(glyphs)
    font.setupHorizontalMetrics(metrics)
    font.setupHorizontalHeader(ascent=units, descent=0)
    font.setupNameTable({
        'familyName': manifest['family'],
        'styleName': 'Regular',
        'uniqueFontIdentifier': f"{manifest['author']};{manifest['family']};{manifest['version']}",
        'fullName': f"{manifest['family']} Regular",
        'psName': manifest['postscript_name'],
        'version': f"Version {manifest['version']}",
        'copyright': manifest['copyright'],
        'manufacturer': manifest['author'],
        'designer': manifest['author'],
        'description': manifest['description'],
        'licenseDescription': f"Licensed under {manifest['license']}; see the repository LICENSE.",
        'licenseInfoURL': manifest['license_url'],
    })
    font.setupOS2(sTypoAscender=units, sTypoDescender=0, sTypoLineGap=0,
                  usWinAscent=units, usWinDescent=0, fsType=0)
    font.setupPost()
    # 固定时间戳，避免相同源稿重新生成时产生二进制差异。
    created = int(datetime.fromisoformat(manifest['created']).replace(
        tzinfo=timezone.utc).timestamp()) + 2082844800
    font.font.recalcTimestamp = False
    font.font['head'].created = created
    font.font['head'].modified = created
    font_path = output / manifest['font']
    font_path.parent.mkdir(parents=True, exist_ok=True)
    font.save(font_path)

    definitions = '\n'.join(
        f"  static const {icon['name']} = IconData({icon['codepoint']}, fontFamily: _family);"
        for icon in entries
    )
    dart = (
        '// GENERATED CODE - DO NOT MODIFY BY HAND.\n'
        f"// {manifest['copyright']}. SPDX-License-Identifier: {manifest['license']}\n"
        '// 源稿与字形映射：tool/artwork/icons/；重新生成：uv run tool/artwork/icons/build_font.py\n'
        '// ignore_for_file: constant_identifier_names\n\n'
        "import 'package:flutter/widgets.dart' show IconData;\n\n"
        '// dart format off\n'
        'abstract final class CustomIcons {\n'
        f"  static const _family = '{manifest['family']}';\n\n"
        f'{definitions}\n'
        '}\n'
    )
    dart_path = output / manifest['dart']
    dart_path.parent.mkdir(parents=True, exist_ok=True)
    dart_path.write_text(dart, encoding='utf-8')
    print(f"Generated {len(entries)} icons: {font_path} and {dart_path}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT,
                        help='产物根目录；默认写回仓库，可指定 build/ 下的目录作一致性检查')
    args = parser.parse_args()
    build(json.loads((SOURCE / 'manifest.json').read_text(encoding='utf-8')), args.output)
