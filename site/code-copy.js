/* Progressively enhance code examples; the guides work without JavaScript. */
async function copyCode(text) {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch { /* Local previews and browser permissions may need the fallback. */ }
  }

  const active = document.activeElement;
  const selection = window.getSelection();
  const ranges = selection ? Array.from({ length: selection.rangeCount }, (_, index) => selection.getRangeAt(index).cloneRange()) : [];
  const buffer = document.createElement('textarea');
  buffer.className = 'code-copy-buffer';
  buffer.value = text;
  buffer.readOnly = true;
  buffer.tabIndex = -1;
  buffer.setAttribute('aria-label', 'Code to copy');
  document.body.append(buffer);
  try {
    buffer.focus({ preventScroll: true });
    buffer.select();
    buffer.setSelectionRange(0, text.length);
    if (!document.execCommand('copy')) throw new Error('Clipboard unavailable');
  } finally {
    buffer.remove();
    if (active instanceof HTMLElement && active.isConnected) active.focus({ preventScroll: true });
    if (selection) {
      selection.removeAllRanges();
      for (const range of ranges) selection.addRange(range);
    }
  }
}

for (const code of document.querySelectorAll('pre > code')) {
  const pre = code.parentElement;
  if (pre.parentElement.classList.contains('code-block')) continue;
  const block = document.createElement('div');
  block.className = 'code-block';
  pre.before(block);
  block.append(pre);

  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'code-copy';
  button.textContent = 'Copy';
  button.setAttribute('aria-label', 'Copy code');
  const status = document.createElement('span');
  status.className = 'code-copy-status';
  status.setAttribute('role', 'status');
  block.append(button, status);

  let reset;
  let copying = false;
  button.addEventListener('click', async () => {
    if (copying) return;
    clearTimeout(reset);
    status.textContent = '';
    copying = true;
    button.setAttribute('aria-disabled', 'true');
    try {
      await copyCode(code.textContent);
      button.textContent = 'Copied';
      status.textContent = 'Code copied to clipboard.';
    } catch {
      button.textContent = 'Try again';
      status.textContent = 'Could not copy. Select the code and copy it manually.';
    } finally {
      copying = false;
      button.removeAttribute('aria-disabled');
      reset = setTimeout(() => { button.textContent = 'Copy'; status.textContent = ''; }, 2500);
    }
  });
}
