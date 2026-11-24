(() => {
  const form = byId('online-search');
  const provider = byId('online-source');
  const type = byId('online-kind');
  const output = byId('online-results');
  const notice = byId('online-notice');
  const more = byId('online-more');
  const controls = {'X-Kontur-Action':'online'};
  let request;
  let lastQuery;
  let next;
  let downloading = false;

  byId('online-tab').onclick = () => {
    byId('workbench').hidden = true;
    byId('online').hidden = false;
    for (const tab of ['library-tab','favorites-tab','online-tab']) {
      byId(tab).setAttribute('aria-pressed',String(tab === 'online-tab'));
    }
    byId('online-query').focus();
  };

  provider.onchange = () => {
    const photosOnly = provider.value === 'flickr';
    type.querySelector('[value="video"]').disabled = photosOnly;
    if (photosOnly) type.value = 'image';
  };

  function node(tag, value) {
    const element = document.createElement(tag);
    if (value) element.textContent = value;
    return element;
  }

  function link(label, url) {
    const element = node('a',label);
    element.href = url;
    element.target = '_blank';
    element.rel = 'noopener noreferrer';
    return element;
  }

  async function add(item, button) {
    if (downloading) return;
    await libraryReady;
    const saved = library.find(record => record.credit?.key === item.key);
    if (saved) { openTab('library',saved); return; }
    if (downloading) return;
    downloading = button.disabled = true;
    button.textContent = 'Загружаю…';
    try {
      const response = await fetch('/online/file/' + item.id,{headers:controls});
      if (!response.ok) throw Error(await response.text());
      const blob = await response.blob();
      if (!blob.size) throw Error('Источник вернул пустой файл.');
      const credit = {key:item.key, author:item.author, rights:item.rights, page:item.page};
      await importFiles([new File([blob], 'wallpaper.' + item.extension, {type:blob.type})], item.title, credit);
    } catch (error) {
      notify(error instanceof TypeError ? 'Загрузка прервалась. Попробуй ещё раз.' : error.message);
    } finally {
      downloading = button.disabled = false;
      button.textContent = 'В библиотеку';
    }
  }

  function card(item) {
    const article = node('article');
    article.className = 'online-card';
    const frame = node('div');
    frame.className = 'online-frame';
    frame.dataset.format = item.extension.toUpperCase();
    if (item.preview) {
      const image = node('img');
      image.alt = '';
      image.loading = 'lazy';
      image.src = '/online/thumb/' + item.id;
      image.onerror = () => image.remove();
      frame.append(image);
    }
    const information = node('div');
    information.className = 'online-card-info';
    const title = node('h3',item.title);
    const details = node('p',[item.author,item.width && item.height ? item.width + ' × ' + item.height : ''].filter(Boolean).join(' · '));
    const actions = node('div');
    actions.className = 'online-card-actions';
    actions.append(item.rights.url ? link(item.rights.label,item.rights.url) : node('span',item.rights.label));
    actions.append(link('Оригинал', item.page));
    const button = node('button','В библиотеку');
    button.type = 'button';
    button.onclick = () => add(item,button);
    actions.append(button);
    information.append(title,details,actions);
    article.append(frame,information);
    return article;
  }

  async function searchOnline(query, isNext = false) {
    request?.abort();
    const current = new AbortController();
    request = current;
    const offset = isNext ? next : 0;
    if (!isNext) output.replaceChildren();
    more.hidden = true;
    notice.textContent = 'Ищу обои…';
    try {
      if (!desktopAvailable) throw Error('Открой «Контур» через ярлык Windows, чтобы искать обои онлайн.');
      const params = new URLSearchParams({...query,offset});
      const response = await fetch('/online/search?' + params,{headers:controls,signal:current.signal});
      if (!response.ok) throw Error(await response.text());
      const {results,next:offsetAfter} = await response.json();
      if (current.signal.aborted) return;
      output.append(...results.map(card));
      lastQuery = query;
      next = offsetAfter;
      more.hidden = next === null;
      notice.textContent = output.childElementCount ? '' : 'Подходящих обоев пока нет. Попробуй другой запрос или следующую страницу.';
    } catch (error) {
      if (current.signal.aborted) return;
      notice.textContent = error instanceof TypeError ? 'Интернет недоступен. Повтори поиск позже.' : error.message;
      more.hidden = !isNext;
    }
  }

  form.onsubmit = event => {
    event.preventDefault();
    const q = byId('online-query').value.trim();
    if (q.length < 2) { notice.textContent = 'Введи хотя бы два символа.'; return; }
    searchOnline({q,source:provider.value,kind:type.value});
  };
  more.onclick = () => searchOnline(lastQuery,true);
})();
