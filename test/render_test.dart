import 'package:flutter_test/flutter_test.dart';
import 'package:trilium_mobile/render.dart';

void main() {
  const html = '<p>Hi</p><img src="api/attachments/abc123/image/foto.png">'
      '<img src="/trilium/api/images/Note_1/bild.jpg"><a class="reference-link" href="#root/x/Ziel1">L</a>';

  test('finds attachment and image-note references', () {
    expect(imageRefs(html), unorderedEquals(['a:abc123', 'n:Note_1']));
  });

  test('inlines known images and leaves unknown ones', () {
    final out = inlineImages(html, (ref) => ref == 'a:abc123' ? 'data:image/png;base64,AA==' : null);
    expect(out, contains('src="data:image/png;base64,AA=="'));
    expect(out, contains('api/images/Note_1/bild.jpg'));
  });

  test('reads note ids from internal links', () {
    expect(noteIdFromLink('#root/x/Ziel1'), 'Ziel1');
    expect(noteIdFromLink('#root/abc?ntxId=1'), 'abc');
    expect(noteIdFromLink('https://example.com'), isNull);
    expect(noteIdFromLink('#'), isNull);
  });

  test('empty paragraphs are no content', () {
    expect(htmlHasContent('<p></p><p>&nbsp;</p>'), isFalse);
    expect(htmlHasContent('<p><img src="x"></p>'), isTrue);
    expect(htmlHasContent('<p>Text</p>'), isTrue);
  });
}
