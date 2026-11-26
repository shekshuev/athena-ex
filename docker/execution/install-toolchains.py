"""Install pinned upstream toolchains under /usr/local (release builds: amd64)."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path('/usr/local')

def fetch(url):
    print("Downloading " + url, flush=True)
    request = urllib.request.Request(url, headers={'User-Agent': 'Athena-runner-build'})
    with urllib.request.urlopen(request, timeout=180) as response:
        return response.read()

# Keep metadata requests small; archives are streamed to unique temporary files.
CHUNK_SIZE = 32 * 1024 * 1024
BUFFER_SIZE = 1024 * 1024
ATTEMPTS = 6
NETWORK_ERRORS = (OSError, urllib.error.URLError, http.client.HTTPException)


def open_download(url, start=None, end=None):
    headers = {'User-Agent': 'Athena-runner-build', 'Accept-Encoding': 'identity'}
    if start is not None:
        headers['Range'] = f'bytes={start}-' + (str(end) if end is not None else '')
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=180)


def content_range(response):
    match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
    if response.status != 206 or not match:
        raise RuntimeError('Server returned an invalid Content-Range')
    return tuple(map(int, match.groups()))


def copy_response(response, output, limit=None):
    copied = 0
    while limit is None or copied < limit:
        amount = BUFFER_SIZE if limit is None else min(BUFFER_SIZE, limit - copied)
        try:
            data = response.read(amount)
        except http.client.IncompleteRead as error:
            output.write(error.partial)
            raise
        if not data:
            break
        output.write(data)
        copied += len(data)
    return copied


def retry_pause(attempt, url, error):
    if attempt == ATTEMPTS - 1:
        raise RuntimeError(f'Download failed after {ATTEMPTS} attempts: {url}') from error
    print(f'Retrying download ({attempt + 1}/{ATTEMPTS}): {url}: {error}', flush=True)
    time.sleep(min(2 ** attempt, 8))


def download_part(url, path, start, end, total):
    for attempt in range(ATTEMPTS):
        offset = path.stat().st_size if path.exists() else 0
        if offset == end - start + 1:
            return
        try:
            with open_download(url, start + offset, end) as response:
                if content_range(response) != (start + offset, end, total):
                    raise RuntimeError('Server changed or ignored the requested byte range')
                with path.open('ab') as output:
                    copy_response(response, output, end - start + 1 - offset)
            if path.stat().st_size != end - start + 1:
                raise OSError('Byte range download ended early')
            return
        except NETWORK_ERRORS as error:
            retry_pause(attempt, url, error)


def download_stream(url, path, expected=None):
    for attempt in range(ATTEMPTS):
        offset = path.stat().st_size if path.exists() else 0
        if expected is not None and offset == expected:
            return
        try:
            with open_download(url, offset if offset else None) as response:
                if response.status == 206:
                    first, last, total = content_range(response)
                    if first != offset or last != total - 1:
                        raise RuntimeError('Invalid resumed download range')
                    if expected is not None and total != expected:
                        raise RuntimeError('Archive size changed while resuming')
                    expected = total
                    mode = 'ab'
                elif response.status == 200:
                    # Servers that ignore Range must restart rather than append.
                    mode = 'wb'
                    size = response.headers.get('Content-Length')
                    expected = int(size) if size is not None else expected
                else:
                    raise RuntimeError(f'Unexpected HTTP status: {response.status}')
                with path.open(mode) as output:
                    copy_response(response, output)
            if expected is not None and path.stat().st_size != expected:
                raise OSError('Archive download ended early')
            return
        except NETWORK_ERRORS as error:
            retry_pause(attempt, url, error)


def download(url, path, checksum=None, algorithm='sha256'):
    print('Downloading archive ' + url, flush=True)
    total = None
    ranged = False
    for attempt in range(ATTEMPTS):
        try:
            # A real Range request is authoritative; Accept-Ranges alone is not.
            with open_download(url, 0, 0) as response:
                if response.status == 206:
                    first, last, total = content_range(response)
                    if (first, last) != (0, 0):
                        raise RuntimeError('Invalid range probe')
                    ranged = True
                else:
                    size = response.headers.get('Content-Length')
                    total = int(size) if size is not None else None
            break
        except NETWORK_ERRORS as error:
            retry_pause(attempt, url, error)
    if ranged and total > CHUNK_SIZE:
        ranges = [(start, min(start + CHUNK_SIZE, total) - 1)
                  for start in range(0, total, CHUNK_SIZE)]
        print(f'Archive size {total} bytes; {len(ranges)} ranges, 8 workers', flush=True)
        with tempfile.TemporaryDirectory(prefix='athena-parts-') as directory:
            parts = [pathlib.Path(directory) / str(index) for index in range(len(ranges))]
            with ThreadPoolExecutor(max_workers=8) as pool:
                futures = [pool.submit(download_part, url, part, start, end, total)
                           for part, (start, end) in zip(parts, ranges)]
                for future in futures:
                    future.result()
            with path.open('wb') as output:
                for part in parts:
                    with part.open('rb') as source:
                        shutil.copyfileobj(source, output, BUFFER_SIZE)
    else:
        download_stream(url, path, total)
    if total is not None and path.stat().st_size != total:
        raise RuntimeError('Archive size mismatch: ' + url)
    if checksum:
        digest = hashlib.new(algorithm)
        with path.open('rb') as source:
            for block in iter(lambda: source.read(BUFFER_SIZE), b''):
                digest.update(block)
        if digest.hexdigest() != checksum.lower():
            raise RuntimeError(algorithm + ' mismatch: ' + url)


def archive(url, destination, checksum=None, strip=1):
    with tempfile.TemporaryDirectory(prefix='athena-archive-') as directory:
        path = pathlib.Path(directory) / 'archive.tar'
        download(url, path, checksum)
        destination = pathlib.Path(destination)
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run(['tar', '-xf', str(path), '-C', str(destination),
                        '--strip-components=' + str(strip)], check=True)


def link(target, name):
    (ROOT/'bin').mkdir(exist_ok=True)
    (ROOT/'bin'/name).symlink_to(target)

family = sys.argv[1]
if family == 'compiled':
    archive('https://go.dev/dl/go1.27.4.linux-amd64.tar.gz', ROOT/'go')
    archive('https://download.swift.org/swift-6.4.3-release/debian12/swift-6.4.3-RELEASE/swift-6.4.3-RELEASE-debian12.tar.gz', ROOT/'swift')
    archive('https://ziglang.org/download/0.17.1/zig-x86_64-linux-0.17.1.tar.xz', ROOT/'zig', '3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a')
    link('/usr/local/go/bin/go', 'go')
    link('/usr/local/swift/usr/bin/swiftc', 'swiftc')
    link('/usr/local/zig/zig', 'zig')
    version = '1.100.0'
    for component in ['rustc', 'rust-std']:
        url = f'https://static.rust-lang.org/dist/{component}-{version}-x86_64-unknown-linux-gnu.tar.xz'
        checksum = fetch(url + '.sha256').decode().split()[0]
        with tempfile.TemporaryDirectory(prefix='athena-rust-') as directory:
            archive(url, directory, checksum)
            subprocess.run([directory + '/install.sh', '--prefix=/usr/local',
                            '--disable-ldconfig'], check=True)
elif family == 'script':
    version = '26.13.1'
    filename = f'node-v{version}-linux-x64.tar.xz'
    sums = fetch(f'https://nodejs.org/dist/v{version}/SHASUMS256.txt').decode().splitlines()
    checksum = next(line.split()[0] for line in sums if line.split()[-1] == filename)
    archive(f'https://nodejs.org/dist/v{version}/{filename}', ROOT, checksum)
    subprocess.run(['/usr/local/bin/npm', 'install', '--global', '--ignore-scripts', '--no-audit', '--no-fund', 'typescript@7.0.2', '@types/node@26.6.6'], check=True)
elif family == 'jvm':
    # Fixed Temurin release; unlike /latest this URL cannot move to a new JDK.
    version = '21.0.13.1+2'
    filename = 'OpenJDK21U-jdk_x64_linux_hotspot_21.0.13.1_2.tar.gz'
    url = 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13.1%2B2/'+filename
    checksum = fetch(url+'.sha256.txt').decode().split()[0]
    archive(url, ROOT/'java', checksum)
    for name in ['java', 'javac']:
        link('/usr/local/java/bin/'+name, name)
    version = '2.4.21'
    with tempfile.TemporaryDirectory(prefix='athena-kotlin-') as directory:
        path = pathlib.Path(directory) / 'kotlin.zip'
        download(f'https://github.com/JetBrains/kotlin/releases/download/v{version}/kotlin-compiler-{version}.zip', path)
        subprocess.run(['unzip', '-q', str(path), '-d', '/usr/local'], check=True)
    link('/usr/local/kotlinc/bin/kotlinc', 'kotlinc')
elif family == 'dotnet':
    metadata = json.loads(fetch('https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'))
    sdk = next(sdk for release in metadata['releases'] for sdk in release.get('sdks', []) if sdk['version'] == '10.0.404')
    package = next(item for item in sdk['files'] if item['rid'] == 'linux-x64' and item['name'].endswith('.tar.gz'))
    with tempfile.TemporaryDirectory(prefix='athena-dotnet-') as directory:
        path = pathlib.Path(directory) / 'dotnet.tar.gz'
        download(package['url'], path, package['hash'], 'sha512')
        (ROOT/'share/dotnet').mkdir(parents=True)
        subprocess.run(['tar', '-xf', str(path), '-C', '/usr/local/share/dotnet'], check=True)
    link('/usr/local/share/dotnet/dotnet', 'dotnet')
else:
    raise ValueError(family)
