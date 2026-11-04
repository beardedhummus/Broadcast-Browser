#!/usr/bin/env python3
"""Minimal Markdown -> standalone HTML converter for the bundled docs.

Handles headings, paragraphs, tables, fenced code, bullet/numbered lists,
horizontal rules, and inline code/bold/italic/links.
Usage: md2html.py input.md output.html
"""
import html
import re
import sys

CSS = """
:root { color-scheme: light dark; --bg:#ffffff; --fg:#1d1d1f; --muted:#6e6e73; --line:#d2d2d7; --code:#f2f2f5; --accent:#d62a36; }
@media (prefers-color-scheme: dark) { :root { --bg:#1c1c1e; --fg:#f2f2f7; --muted:#a1a1a6; --line:#3a3a3c; --code:#2c2c2e; --accent:#ff5a63; } }
body { background:var(--bg); color:var(--fg); font:15px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; margin:0; }
main { max-width: 980px; margin: 0 auto; padding: 32px 24px 80px; }
h1 { font-size: 30px; margin: 0 0 12px; } h2 { font-size: 22px; margin-top: 40px; border-bottom: 1px solid var(--line); padding-bottom: 6px; }
h3 { font-size: 18px; margin-top: 28px; } h4 { font-size: 15px; margin-top: 22px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
code { font: 13px/1.4 ui-monospace, "SF Mono", Menlo, monospace; background: var(--code); padding: 1px 5px; border-radius: 4px; }
pre { background: var(--code); padding: 14px 16px; border-radius: 8px; overflow-x: auto; }
pre code { background: none; padding: 0; }
table { border-collapse: collapse; width: 100%; margin: 12px 0 20px; font-size: 14px; display: block; overflow-x: auto; }
th, td { border-bottom: 1px solid var(--line); padding: 7px 10px; text-align: left; vertical-align: top; }
th { color: var(--muted); font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: .04em; }
td code { white-space: nowrap; }
a { color: var(--accent); }
hr { border: 0; border-top: 1px solid var(--line); margin: 32px 0; }
"""


def inline(text):
    parts = re.split(r"(`[^`]*`)", text)
    out = []
    for part in parts:
        if part.startswith("`") and part.endswith("`") and len(part) >= 2:
            out.append("<code>" + html.escape(part[1:-1]) + "</code>")
            continue
        s = html.escape(part)
        s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
        s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"(?<![\w*])\*([^*\n]+)\*(?![\w*])", r"<em>\1</em>", s)
        out.append(s)
    return "".join(out)


def split_row(line):
    line = line.strip().strip("|")
    cells, current, in_code = [], "", False
    for ch in line:
        if ch == "`":
            in_code = not in_code
        if ch == "|" and not in_code:
            cells.append(current.strip())
            current = ""
        else:
            current += ch
    cells.append(current.strip())
    return cells


def convert(md):
    lines = md.split("\n")
    out, i, title = [], 0, "Documentation"
    paragraph = []

    def flush():
        if paragraph:
            out.append("<p>" + inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("```"):
            flush()
            code = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            out.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
            i += 1
            continue
        heading = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if heading:
            flush()
            level = len(heading.group(1))
            if level == 1:
                title = heading.group(2)
            anchor = re.sub(r"[^a-z0-9]+", "-", heading.group(2).lower()).strip("-")
            out.append(f'<h{level} id="{anchor}">{inline(heading.group(2))}</h{level}>')
            i += 1
            continue
        if stripped == "---":
            flush()
            out.append("<hr>")
            i += 1
            continue
        if stripped.startswith("|"):
            flush()
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            header, body = rows[0], [r for r in rows[1:] if not all(re.fullmatch(r":?-{2,}:?", c) for c in r)]
            table = ["<table><thead><tr>"] + [f"<th>{inline(c)}</th>" for c in header] + ["</tr></thead><tbody>"]
            for row in body:
                table.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>")
            table.append("</tbody></table>")
            out.append("".join(table))
            continue
        bullet = re.match(r"^(\s*)([*-]|\d+\.)\s+(.*)$", line)
        if bullet:
            flush()
            ordered = bullet.group(2)[0].isdigit()
            tag = "ol" if ordered else "ul"
            items = []
            while i < len(lines):
                m = re.match(r"^(\s*)([*-]|\d+\.)\s+(.*)$", lines[i])
                if m:
                    items.append(m.group(3))
                elif lines[i].startswith("   ") and lines[i].strip() and items:
                    items[-1] += " " + lines[i].strip()
                else:
                    break
                i += 1
            out.append(f"<{tag}>" + "".join(f"<li>{inline(it)}</li>" for it in items) + f"</{tag}>")
            continue
        if not stripped:
            flush()
        else:
            paragraph.append(stripped)
        i += 1
    flush()
    body = "\n".join(out)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title><style>{CSS}</style></head>
<body><main>
{body}
</main></body></html>
"""


if __name__ == "__main__":
    source, destination = sys.argv[1], sys.argv[2]
    with open(source, encoding="utf-8") as f:
        result = convert(f.read())
    with open(destination, "w", encoding="utf-8") as f:
        f.write(result)
