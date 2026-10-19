"""Build a single-file review copy of the Listen Room page (assets/listen_room/)
with the review stand-in for the app (dev/dev-host.js) included.

    python yinwei/tools/listen_room_review.py OUT.html

Everything local is inlined: styles, scripts, and fonts as data URIs. A vendor
script or font that is not in the folder yet falls back to the public CDN copy
the prototype used, and the build says so; the app's own build never does that
(the offline contract test fails instead). Review use only: nothing here is shipped.
"""
import base64, os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "apps", "yinwei_player", "assets", "listen_room")
CDN_THREE = "https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"
CDN_EXAMPLES = "https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/"
FONT_LINKS = [
    "https://fonts.googleapis.com/css2?family=Outfit:wght@200;300;400;500;600&display=swap",
    "https://fonts.googleapis.com/css2?family=Material+Symbols+Rounded:opsz,wght,FILL,GRAD@20..48,100..700,0..1,-50..200"
    "&icon_names=add,airplay,call,devices,expand_more,graphic_eq,headphones,info,more_horiz,music_off,pause,play_arrow,radar,"
    "skip_next,skip_previous,speaker,stop_circle,touch_app,view_in_ar,volume_up,wifi_off&display=block",
]


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def main(out):
    notes = []
    page = read("index.html")
    css = read("ui.css")
    missing_fonts = False
    mime = {".woff2": "font/woff2", ".jpg": "image/jpeg", ".png": "image/png"}
    for m in re.findall(r'url\("((?!data:)[^"]+)"\)', css):
        path = os.path.join(ROOT, m)
        if os.path.exists(path):
            data = base64.b64encode(open(path, "rb").read()).decode("ascii")
            css = css.replace(f'url("{m}")', f'url("data:{mime[os.path.splitext(m)[1]]};base64,{data}")')
        elif m.startswith("fonts/"):
            missing_fonts = True
            notes.append(f"font {m} missing: using Google Fonts")
        else:
            raise SystemExit(f"missing page file: {m}")
    if missing_fonts:
        css = re.sub(r"@font-face \{[^}]*fonts/[^}]*\}\n", "", css)
    head = "".join(f'<link rel="stylesheet" href="{u}">\n' for u in FONT_LINKS) if missing_fonts else ""
    page = page.replace('<link rel="stylesheet" href="ui.css">', head + "<style>\n" + css + "</style>")

    def script(m):
        src = m.group(1)
        path = os.path.join(ROOT, src)
        if os.path.exists(path):
            return "<script>\n" + read(src).replace("</script", "<\\/script") + "\n</script>"
        if src == "vendor/three.min.js":
            notes.append(f"{src} missing: using {CDN_THREE}")
            return f'<script src="{CDN_THREE}"></script>'
        if src.startswith("vendor/examples/"):
            url = CDN_EXAMPLES + src[len("vendor/examples/"):]
            notes.append(f"{src} missing: using {url}")
            return f'<script src="{url}"></script>'
        raise SystemExit(f"missing page script: {src}")
    page = re.sub(r'<script src="([^"]+)"></script>', script, page)
    dev = read("dev/dev-host.js").replace("</script", "<\\/script")
    page = page.replace("</body>", "<script>\n" + dev + "\n</script>\n</body>")
    # The artifact host supplies its own document skeleton: keep the title and body content only.
    title = re.search(r"<title>.*?</title>", page).group(0)
    body = page[page.index("<style>"):page.index("</head>")] + page[page.index("<body>") + 6:page.index("</body>")]
    links = head
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(title + "\n" + links + body)
    print(f"wrote {out} ({os.path.getsize(out)} bytes)")
    for n in notes:
        print("  note:", n)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
