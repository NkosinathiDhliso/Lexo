import 'dotenv/config';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, '..');

const distDir = path.resolve(projectRoot, process.env.STATIC_DIST_DIR ?? 'dist');
const region =
  process.env.AWS_REGION ??
  process.env.VITE_AWS_S3_REGION ??
  process.env.VITE_AWS_REGION ??
  'us-east-1';
const bucket =
  process.env.STATIC_SITE_BUCKET ??
  process.env.S3_STATIC_SITE_BUCKET ??
  process.env.VITE_STATIC_SITE_BUCKET;
const prefix = normalizePrefix(process.env.STATIC_SITE_PREFIX ?? '');
const dryRun = process.argv.includes('--dry-run');

if (!bucket) {
  console.error(
    'Missing STATIC_SITE_BUCKET (or S3_STATIC_SITE_BUCKET / VITE_STATIC_SITE_BUCKET).'
  );
  process.exit(1);
}

const client = new S3Client({ region });

main().catch((error) => {
  console.error('Deployment failed:', error);
  process.exit(1);
});

async function main() {
  const exists = await pathExists(distDir);
  if (!exists) {
    console.error(`Build output directory not found: ${distDir}`);
    console.error('Run npm run build before deploy.');
    process.exit(1);
  }

  const files = await listFiles(distDir);
  if (files.length === 0) {
    console.error(`No files found in ${distDir}`);
    process.exit(1);
  }

  console.log(`Uploading ${files.length} files to s3://${bucket}/${prefix}`);
  console.log(`Region: ${region}`);
  if (dryRun) {
    console.log('Dry run enabled (no upload requests will be sent).');
  }

  let uploaded = 0;

  for (const absolutePath of files) {
    const relativePath = normalizeSlashes(path.relative(distDir, absolutePath));
    const key = prefix ? `${prefix}/${relativePath}` : relativePath;
    const contentType = getContentType(relativePath);
    const cacheControl = getCacheControl(relativePath);

    if (dryRun) {
      console.log(`[DRY RUN] ${key} | ${contentType} | ${cacheControl}`);
      uploaded += 1;
      continue;
    }

    const body = await fs.readFile(absolutePath);

    await client.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        Body: body,
        ContentType: contentType,
        CacheControl: cacheControl,
      })
    );

    uploaded += 1;
    console.log(`Uploaded ${uploaded}/${files.length}: ${key}`);
  }

  console.log(`Done. ${uploaded} files processed.`);
  console.log('JavaScript assets were uploaded with explicit JavaScript MIME types.');
}

async function listFiles(directory) {
  const entries = await fs.readdir(directory, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await listFiles(entryPath)));
    } else {
      files.push(entryPath);
    }
  }

  return files;
}

async function pathExists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

function normalizePrefix(value) {
  return value.replace(/^\/+|\/+$/g, '');
}

function normalizeSlashes(value) {
  return value.split(path.sep).join('/');
}

function getCacheControl(relativePath) {
  const normalized = normalizeSlashes(relativePath);

  if (normalized === 'index.html' || normalized === 'sw.js') {
    return 'no-cache, no-store, must-revalidate';
  }

  if (normalized.startsWith('assets/')) {
    return 'public, max-age=31536000, immutable';
  }

  return 'public, max-age=3600';
}

function getContentType(relativePath) {
  const extension = path.extname(relativePath).toLowerCase();

  switch (extension) {
    case '.html':
      return 'text/html; charset=utf-8';
    case '.js':
    case '.mjs':
      return 'application/javascript; charset=utf-8';
    case '.css':
      return 'text/css; charset=utf-8';
    case '.json':
    case '.map':
      return 'application/json; charset=utf-8';
    case '.svg':
      return 'image/svg+xml';
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.webp':
      return 'image/webp';
    case '.gif':
      return 'image/gif';
    case '.ico':
      return 'image/x-icon';
    case '.woff':
      return 'font/woff';
    case '.woff2':
      return 'font/woff2';
    case '.ttf':
      return 'font/ttf';
    case '.eot':
      return 'application/vnd.ms-fontobject';
    case '.txt':
      return 'text/plain; charset=utf-8';
    case '.webmanifest':
      return 'application/manifest+json; charset=utf-8';
    default:
      return 'application/octet-stream';
  }
}
