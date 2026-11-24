const themeButtons = document.querySelectorAll('[data-set-theme]');
function setTheme(theme, remember = false) {
  if (theme !== 'day' && theme !== 'night') return;
  document.documentElement.dataset.theme = theme;
  if (remember && musicEnabled) playThemeMusic();
  for (const button of themeButtons) {
    button.setAttribute('aria-pressed', String(button.dataset.setTheme === theme));
  }
  if (remember) {
    try { localStorage.setItem('kontur.theme', theme); }
    catch { /* The chosen theme remains active for the current session. */ }
  }
}
const musicButton = byId('music-toggle');
const musicVolume = byId('music-volume');
const soundtrack = new Audio();
soundtrack.loop = true;
let musicEnabled = false;
let audioTheme;
let playRequest = 0;
try {
  const value = localStorage.getItem('kontur.musicVolume');
  if (value !== null) musicVolume.value = value;
} catch { /* Keep the default level. */ }
soundtrack.volume = Number(musicVolume.value) / 100;

function updateMusicButton() {
  musicButton.setAttribute('aria-pressed', String(musicEnabled));
  musicButton.title = musicEnabled ? 'Выключить звуки природы' : 'Включить звуки природы';
}
async function playThemeMusic() {
  const request = ++playRequest;
  const theme = document.documentElement.dataset.theme;
  if (audioTheme !== theme) {
    soundtrack.src = '../assets/' + theme + '.wav';
    audioTheme = theme;
  }
  try { await soundtrack.play(); }
  catch {
    if (request !== playRequest) return;
    musicEnabled = false;
    updateMusicButton();
    notify('Не удалось воспроизвести звуки природы.');
  }
}
musicButton.addEventListener('click', () => {
  musicEnabled = !musicEnabled;
  updateMusicButton();
  if (musicEnabled) playThemeMusic();
  else {
    playRequest++;
    soundtrack.pause();
  }
});
musicVolume.addEventListener('input', () => {
  soundtrack.volume = Number(musicVolume.value) / 100;
  try { localStorage.setItem('kontur.musicVolume', musicVolume.value); } catch {}
});
updateMusicButton();

try { setTheme(localStorage.getItem('kontur.theme')); }
catch { /* The default theme is already shown. */ }
for (const button of themeButtons) {
  button.addEventListener('click', () => setTheme(button.dataset.setTheme, true));
}
