/**
 * Container fingerprints, checked before a download is called finished.
 *
 * A 200 response proves nothing about the bytes. Servers hand back login walls,
 * expiry notices, and — in YouTube's case — protocol-framed data that is not a
 * media file at all. Every one of those arrives as a successful HTTP response
 * with a plausible content type, and every one of them lands on disk as a file
 * that opens in nothing.
 *
 * The first few bytes of a real container are unambiguous, so they are what we
 * trust.
 */

interface Signature {
  /** Extensions this rule governs. */
  extensions: string[];
  /** Byte pattern, with `null` meaning "any value here". */
  magic: Array<number | null>;
  offset: number;
  label: string;
}

const SIGNATURES: Signature[] = [
  // ISO base media: the 'ftyp' box follows a 4-byte size.
  {
    extensions: ['mp4', 'm4a', 'm4v', 'mov'],
    magic: [null, null, null, null, 0x66, 0x74, 0x79, 0x70],
    offset: 0,
    label: 'MP4',
  },
  // Matroska and WebM share the EBML header.
  {
    extensions: ['webm', 'mkv'],
    magic: [0x1a, 0x45, 0xdf, 0xa3],
    offset: 0,
    label: 'WebM',
  },
  { extensions: ['ogg', 'opus'], magic: [0x4f, 0x67, 0x67, 0x53], offset: 0, label: 'Ogg' },
  { extensions: ['flac'], magic: [0x66, 0x4c, 0x61, 0x43], offset: 0, label: 'FLAC' },
  { extensions: ['wav'], magic: [0x52, 0x49, 0x46, 0x46], offset: 0, label: 'RIFF' },
  { extensions: ['jpg', 'jpeg'], magic: [0xff, 0xd8, 0xff], offset: 0, label: 'JPEG' },
  {
    extensions: ['png'],
    magic: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    offset: 0,
    label: 'PNG',
  },
  { extensions: ['gif'], magic: [0x47, 0x49, 0x46, 0x38], offset: 0, label: 'GIF' },
  { extensions: ['webp'], magic: [0x52, 0x49, 0x46, 0x46], offset: 0, label: 'RIFF' },
  { extensions: ['pdf'], magic: [0x25, 0x50, 0x44, 0x46], offset: 0, label: 'PDF' },
  { extensions: ['zip', 'apk', 'docx', 'xlsx', 'pptx'], magic: [0x50, 0x4b], offset: 0, label: 'ZIP' },
  { extensions: ['rar'], magic: [0x52, 0x61, 0x72, 0x21], offset: 0, label: 'RAR' },
  { extensions: ['7z'], magic: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c], offset: 0, label: '7-Zip' },
  { extensions: ['gz', 'tgz'], magic: [0x1f, 0x8b], offset: 0, label: 'gzip' },
  { extensions: ['dmg'], magic: [0x78, 0x01], offset: 0, label: 'DMG' },
];

/**
 * MP3 is checked separately: it has no single header. A file may open with an
 * ID3 tag or go straight into a frame whose sync word only pins the first
 * eleven bits.
 */
function looksLikeMp3(bytes: Uint8Array): boolean {
  if (bytes.length < 3) return false;
  if (bytes[0] === 0x49 && bytes[1] === 0x44 && bytes[2] === 0x33) return true;
  return bytes[0] === 0xff && (bytes[1]! & 0xe0) === 0xe0;
}

export interface SignatureVerdict {
  /** False only when the extension is known and the bytes contradict it. */
  ok: boolean;
  expected?: string;
}

/**
 * An unknown extension is not a failure — plenty of legitimate files have no
 * recognisable header, and refusing them would be worse than useless. Only a
 * direct contradiction is reported.
 */
export function verifySignature(extension: string, bytes: Uint8Array): SignatureVerdict {
  const ext = extension.toLowerCase().replace(/^\./, '');

  if (ext === 'mp3') {
    return looksLikeMp3(bytes) ? { ok: true } : { ok: false, expected: 'MP3' };
  }

  const rule = SIGNATURES.find((entry) => entry.extensions.includes(ext));
  if (!rule) return { ok: true };

  if (bytes.length < rule.offset + rule.magic.length) {
    return { ok: false, expected: rule.label };
  }

  for (let index = 0; index < rule.magic.length; index++) {
    const expected = rule.magic[index];
    if (expected === null) continue;
    if (bytes[rule.offset + index] !== expected) {
      return { ok: false, expected: rule.label };
    }
  }

  return { ok: true };
}
