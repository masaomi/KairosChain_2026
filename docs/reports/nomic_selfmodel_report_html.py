#!/usr/bin/env python3
"""Render the self-model report's markdown into styled HTML (ja + en).

The markdown is the single source; this only restyles it. Writing the HTML by
hand would let the two drift, which has bitten this project before.

Handles the subset the report actually uses: headings, paragraphs, fenced code,
pipe tables, blockquotes, images, links, bold, inline code, bullet lists,
horizontal rules and trailing italics.

Usage:  python3 docs/reports/nomic_selfmodel_report_html.py
Reads:  docs/reports/nomic_bench_selfmodel_report_20260914_{ja,en}.md
Writes: the same names with .html
"""

import html
import pathlib
import re

OUT = pathlib.Path(__file__).resolve().parent
STEM = "nomic_bench_selfmodel_report_20260914"

CSS = """
:root{--ink:#1a2332;--dim:#5b6068;--line:#dcdfe4;--bg:#fbfbfc;--panel:#fff;
  --green:#1f7a4d;--red:#a02c2c;--hi:#f6efd8;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
  font:16.5px/1.85 "Hiragino Sans","Yu Gothic",-apple-system,system-ui,sans-serif}
.wrap{max-width:920px;margin:0 auto;padding:0 24px 120px}
h1{font-size:31px;line-height:1.4;margin:52px 0 14px}
h1+p{color:var(--dim);font-size:15px;margin:0 0 6px}
h1+p strong,h1+p+p strong{background:none;padding:0;font-weight:600}
h2{font-size:23px;margin:64px 0 18px;padding-bottom:10px;
  border-bottom:2px solid var(--ink)}
h3{font-size:18px;margin:34px 0 12px;color:var(--green)}
p{margin:0 0 16px}
b,strong{background:var(--hi);padding:1px 4px;border-radius:2px}
img{display:block;width:100%;height:auto;margin:26px 0 32px;border-radius:8px;
  border:1px solid var(--line)}
pre{background:#22252b;color:#e6e9ef;padding:20px 22px;border-radius:7px;
  overflow-x:auto;font:13px/1.72 var(--mono);margin:0 0 22px}
code{font:13.5px var(--mono);background:#eceef1;padding:1px 5px;border-radius:3px}
pre code{background:none;padding:0;font-size:inherit;color:inherit}
table{border-collapse:collapse;width:100%;margin:0 0 24px;font-size:14.5px;
  background:var(--panel)}
th,td{border:1px solid var(--line);padding:8px 11px;text-align:left;
  vertical-align:top}
th{background:#f0f2f4;font-weight:600;font-size:13.5px}
blockquote{border-left:4px solid var(--ink);background:var(--panel);margin:0 0 22px;
  padding:16px 20px;font-size:15.5px}
blockquote p:last-child{margin:0}
ul{margin:0 0 20px;padding-left:26px}
li{margin:0 0 8px}
hr{border:0;border-top:1px solid var(--line);margin:44px 0}
a{color:var(--green)}
em{color:var(--dim)}
footer{margin-top:56px;padding-top:20px;border-top:1px solid var(--line);
  color:var(--dim);font-size:13.5px}
@media (max-width:640px){.wrap{padding:0 16px 80px}h1{font-size:25px}}
"""


def inline(s):
    # The Japanese edition uses literal <strong> tags, because CommonMark only
    # opens ** at a word boundary and Japanese has none — see the 2026-09-15
    # fix. Protect that one tag from escaping; everything else is still escaped.
    s = s.replace("<strong>", "\x00S\x00").replace("</strong>", "\x00E\x00")
    s = html.escape(s, quote=False)
    s = s.replace("\x00S\x00", "<strong>").replace("\x00E\x00", "</strong>")
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    s = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', s)
    s = re.sub(r'\*([^*]+)\*', r'<em>\1</em>', s)
    s = re.sub(r'!\[([^\]]*)\]\(([^)]+)\)', r'<img src="\2" alt="\1">', s)
    s = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', s)
    return s


def row(line):
    return [c.strip() for c in line.strip().strip('|').split('|')]


def convert(md):
    out, i, lines = [], 0, md.split('\n')
    while i < len(lines):
        ln = lines[i]

        if ln.startswith('```'):                       # fenced code
            i += 1
            buf = []
            while i < len(lines) and not lines[i].startswith('```'):
                buf.append(html.escape(lines[i], quote=False))
                i += 1
            out.append('<pre><code>' + '\n'.join(buf) + '</code></pre>')
            i += 1
            continue

        if ln.startswith('|') and i + 1 < len(lines) and \
                re.match(r'^\|[\s:|-]+\|$', lines[i + 1].strip()):
            head = row(ln)
            i += 2
            body = []
            while i < len(lines) and lines[i].startswith('|'):
                body.append(row(lines[i]))
                i += 1
            t = ['<table><thead><tr>'] + \
                [f'<th>{inline(c)}</th>' for c in head] + ['</tr></thead><tbody>']
            for r in body:
                t += ['<tr>'] + [f'<td>{inline(c)}</td>' for c in r] + ['</tr>']
            out.append(''.join(t) + '</tbody></table>')
            continue

        if ln.startswith('> '):                        # blockquote
            buf = []
            while i < len(lines) and lines[i].startswith('>'):
                buf.append(lines[i].lstrip('>').strip())
                i += 1
            out.append('<blockquote><p>' +
                       '<br>'.join(inline(x) for x in buf if x) +
                       '</p></blockquote>')
            continue

        if ln.startswith('- '):                        # bullet list
            buf = []
            while i < len(lines) and (lines[i].startswith('- ') or
                                      lines[i].startswith('  ')):
                if lines[i].startswith('- '):
                    buf.append(lines[i][2:])
                else:
                    buf[-1] += ' ' + lines[i].strip()
                i += 1
            out.append('<ul>' +
                       ''.join(f'<li>{inline(x)}</li>' for x in buf) + '</ul>')
            continue

        m = re.match(r'^(#{1,3}) (.*)$', ln)
        if m:
            lv = len(m.group(1))
            out.append(f'<h{lv}>{inline(m.group(2))}</h{lv}>')
            i += 1
            continue

        if ln.strip() == '---':
            out.append('<hr>')
            i += 1
            continue

        if ln.strip() == '':
            i += 1
            continue

        buf = []                                       # paragraph
        while i < len(lines) and lines[i].strip() and \
                not re.match(r'^(#{1,3} |```|\||> |- |---$)', lines[i]):
            buf.append(lines[i].strip())
            i += 1
        body = inline(' '.join(buf))
        out.append(body if body.startswith('<img') else f'<p>{body}</p>')

    return '\n'.join(out)


def main():
    for lang in ('ja', 'en'):
        src = OUT / f"{STEM}_{lang}.md"
        md = src.read_text(encoding='utf-8')
        # markdown links between the two editions point at .md; inside the HTML
        # edition they should point at the sibling .html.
        md = md.replace(f"{STEM}_en.md)", f"{STEM}_en.html)")
        md = md.replace(f"{STEM}_ja.md)", f"{STEM}_ja.html)")
        title = md.split('\n', 1)[0].lstrip('# ').strip()
        page = (f'<!DOCTYPE html>\n<html lang="{lang}">\n<head>\n'
                f'<meta charset="utf-8">\n'
                f'<meta name="viewport" content="width=device-width,'
                f'initial-scale=1">\n'
                f'<title>{html.escape(title)}</title>\n<style>{CSS}</style>\n'
                f'</head>\n<body><div class="wrap">\n' + convert(md) +
                '\n</div></body>\n</html>\n')
        dst = OUT / f"{STEM}_{lang}.html"
        dst.write_text(page, encoding='utf-8')
        print(f"wrote {dst.name} ({dst.stat().st_size:,} bytes) "
              f"from {src.name}")


if __name__ == "__main__":
    main()
