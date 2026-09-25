# Накласти текстовий шар на PDF із зображеннями.
#
#   python ns-textlayer.py <зображення.pdf> <текст.pdf> <вихід.pdf>
#
# Навіщо це окремим кроком, а не через ocrmypdf: Tesseract помітно краще
# розпізнає СІРИЙ переклад сторінки, ніж кольорове зображення. Виміряно на
# стор. 1 номера 2225 — блакитні заголовки, яких у кольоровому варіанті не
# видно зовсім:
#     «Зустріч президентів держав Центральної і Східної Європи»  кольорове -
#     «Енджіоси» в боротьбі з «Матріксом»                        кольорове -
# у сірому перекладі знаходяться всі. Порогові режими самого ocrmypdf
# (--tesseract-thresholding otsu/adaptive-otsu/sauvola) дають лише часткове
# й непослідовне покращення.
#
# Тому: розпізнаємо сірий, а віддаємо кольоровий. Tesseract із
# `-c textonly_pdf=1` робить PDF з самим лише невидимим текстом, без
# зображення, і його лишається накласти на кольорові сторінки.

import sys
import pikepdf


def main():
    if len(sys.argv) != 4:
        sys.stderr.write("usage: ns-textlayer.py images.pdf text.pdf out.pdf\n")
        return 2

    images, text, out = sys.argv[1:4]
    img = pikepdf.open(images)
    txt = pikepdf.open(text)

    if len(img.pages) != len(txt.pages):
        sys.stderr.write(
            "storinok ne zbigaietsia: images=%d text=%d\n" % (len(img.pages), len(txt.pages)))
        return 1

    for i, page in enumerate(img.pages):
        # Межі сторінок збігаються, бо обидва PDF походять від тих самих
        # зображень 300 dpi. add_overlay сам приведе систему координат, якщо
        # десь виникне розбіжність.
        page.add_overlay(txt.pages[i])

    img.save(out)
    sys.stdout.write("ok %d\n" % len(img.pages))
    return 0


if __name__ == "__main__":
    sys.exit(main())
