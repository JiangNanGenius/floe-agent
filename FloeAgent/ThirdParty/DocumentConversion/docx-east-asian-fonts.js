import JSZip from 'jszip';

// HTMLtoDOCX names only a Latin family (Arial) and points East Asian text at the
// theme's minor HAnsi font, which it also sets to Arial. Arial carries no CJK
// glyphs, so Chinese/Japanese/Korean runs render as empty squares in the native
// editor, whose theme/docDefaults East Asian resolution is unreliable on iOS.
// Mirror the native Word builder (OfficeDocumentBuilders): name the installed
// system CJK family on every run, in the document defaults, in the theme and in
// the font table, and mark the East Asian language zh-CN. Latin text keeps
// Arial; complex-script (bidi) fonts are left untouched.
export const eastAsianFont = 'PingFang SC';
export const eastAsianLang = 'zh-CN';
export const eastAsianRunFonts = `<w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="${eastAsianFont}"/>`;

/// Rewrite the East Asian font declarations of a generated .docx package so CJK
/// text resolves to an installed family. Returns a new Uint8Array; the input is
/// not mutated. Purely zip/XML work — no DOM — so it runs in the converter's
/// WKWebView and in a plain Node module test alike.
export async function applyEastAsianFonts(bytes) {
  const zip = await JSZip.loadAsync(bytes);
  const documentPart = zip.file('word/document.xml');
  if (documentPart) {
    let xml = await documentPart.async('string');
    // Runs the converter emits carry an empty <w:rPr/>; give each explicit fonts.
    xml = xml.replace(/<w:rPr\s*\/>/g, `<w:rPr>${eastAsianRunFonts}</w:rPr>`);
    // Runs that already have properties but no font get them inserted in schema
    // order (after rStyle, before b/i/sz/color).
    xml = xml.replace(/<w:rPr>([\s\S]*?)<\/w:rPr>/g, (match, inner) => {
      if (inner.indexOf('<w:rFonts') !== -1) return match;
      if (/^\s*<w:rStyle[^>]*\/>/.test(inner)) return match.replace(/<w:rStyle[^>]*\/>/, (m) => m + eastAsianRunFonts);
      return `<w:rPr>${eastAsianRunFonts}${inner}</w:rPr>`;
    });
    // Any run left without properties at all still needs the CJK family.
    xml = xml.replace(/<w:r>(?!\s*<w:rPr)/g, `<w:r><w:rPr>${eastAsianRunFonts}</w:rPr>`);
    zip.file('word/document.xml', xml);
  }
  const stylesPart = zip.file('word/styles.xml');
  if (stylesPart) {
    let xml = await stylesPart.async('string');
    xml = xml.replace(/<w:rFonts\b([^>]*?)\/>/g, (match, attrs) => {
      if (/\bw:eastAsia\s*=/.test(attrs)) return match;
      return `<w:rFonts${attrs.replace(/\s*w:eastAsiaTheme="[^"]*"/g, '')} w:eastAsia="${eastAsianFont}"/>`;
    });
    xml = xml.replace(/<w:lang\b([^>]*?)\/>/g, (match, attrs) => {
      if (!/\bw:eastAsia\s*=/.test(attrs)) return match;
      return `<w:lang${attrs.replace(/w:eastAsia="[^"]*"/, `w:eastAsia="${eastAsianLang}"`)}\/>`;
    });
    zip.file('word/styles.xml', xml);
  }
  const themePart = zip.file('word/theme/theme1.xml');
  if (themePart) {
    let xml = await themePart.async('string');
    xml = xml.replace(/(<a:ea\s+typeface=")[^"]*(")/g, `$1${eastAsianFont}$2`);
    zip.file('word/theme/theme1.xml', xml);
  }
  const fontTablePart = zip.file('word/fontTable.xml');
  if (fontTablePart) {
    let xml = await fontTablePart.async('string');
    if (!xml.includes(`w:name="${eastAsianFont}"`)) {
      xml = xml.replace(/<\/w:fonts>/, `<w:font w:name="${eastAsianFont}"><w:charset w:val="86"/><w:family w:val="swiss"/><w:pitch w:val="variable"/></w:font></w:fonts>`);
      zip.file('word/fontTable.xml', xml);
    }
  }
  return new Uint8Array(await zip.generateAsync({ type: 'arraybuffer', compression: 'DEFLATE', compressionOptions: { level: 6 } }));
}
