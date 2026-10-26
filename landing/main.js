'use strict';

(() => {
  const phone = document.querySelector('[data-demo="phone"]');
  const chat = document.querySelector('[data-demo="chat"]');
  const heard = phone.querySelector('.heard');
  const typed = phone.querySelector('.typed');
  const send = phone.querySelector('.send');
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const spoken =
    'Lavender-Infused Vegan Pancakes with Whipped Coconut Yogurt, Strawberry Compote, Fresh Blueberries, Pink Dragon Fruit Purée, Edible Rose Petals, Chia Seeds & Organic Agave Drizzle.';
  const written = 'Өчпочмакларым яңа гына пеште, токмачлы ашым да әзер, баллы чәй дә бар!';
  // Day totals after the ChatGPT meal, the spoken meal and the typed meal.
  const days = [
    { calories: 0, protein: 0, fiber: 0 },
    { calories: 300, protein: 15, fiber: 2 },
    { calories: 1010, protein: 31, fiber: 13 },
    { calories: 1610, protein: 59, fiber: 17 },
  ];
  let visible = true;

  const show = (totals) => {
    phone.querySelector('[data-key="calories"]').textContent =
      totals.calories.toLocaleString('en-US');
    phone.querySelector('[data-key="protein"]').textContent = totals.protein + ' g';
    phone.querySelector('[data-key="fiber"]').textContent = totals.fiber + ' g';
  };

  // Resolves after `ms` of visible time, so the demo pauses while scrolled away.
  const wait = (ms) =>
    new Promise((resolve) => {
      let last = performance.now();
      const tick = (now) => {
        if (visible && !document.hidden) ms -= now - last;
        last = now;
        if (ms <= 0) resolve();
        else requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });

  const count = (from, to, duration = 500) =>
    new Promise((resolve) => {
      const start = performance.now();
      const frame = (now) => {
        const t = Math.min((now - start) / duration, 1);
        const eased = 1 - Math.pow(1 - t, 3);
        const value = (key) => Math.round(from[key] + (to[key] - from[key]) * eased);
        show({ calories: value('calories'), protein: value('protein'), fiber: value('fiber') });
        if (t < 1) requestAnimationFrame(frame);
        else resolve();
      };
      requestAnimationFrame(frame);
    });

  // Step 1 is the request, 2–4 are tool calls, 5 is the reply.
  const step = (current) => {
    for (const item of chat.querySelectorAll('[data-at]')) {
      const at = Number(item.dataset.at);
      item.classList.toggle('shown', at <= current);
      item.classList.toggle('active', at === current);
    }
  };

  const hear = (text) => {
    if (text) heard.firstElementChild.textContent = text;
    heard.classList.toggle('shown', Boolean(text));
  };

  const type = (text) => {
    typed.textContent = text;
    send.classList.toggle('ready', text.length > 0);
  };

  const reset = () => {
    step(0);
    show(days[0]);
    hear('');
    type('');
    phone.dataset.state = 'idle';
    phone.dataset.sheet = '';
    send.querySelector('.send-label').textContent = 'Send';
  };

  const settle = () => {
    reset();
    step(5);
    show(days[3]);
  };

  async function viaChat() {
    step(1);
    await wait(700);
    for (let call = 2; call <= 4; call++) {
      step(call);
      await wait(600);
    }
    step(5);
    await count(days[0], days[1]);
    await wait(1000);
  }

  async function viaVoice() {
    phone.dataset.state = 'recording';
    const timer = phone.querySelector('.timer');
    for (let second = 0; second < 3; second++) {
      timer.textContent = '0:0' + second;
      await wait(1000);
    }
    phone.dataset.state = 'transcribing';
    await wait(600);
    phone.dataset.state = 'analyzing';
    hear(spoken);
    await wait(1000);
    phone.dataset.state = 'done';
    await count(days[1], days[2]);
    await wait(1200);
    hear('');
  }

  async function viaKeyboard() {
    phone.dataset.sheet = 'open';
    await wait(450);
    for (const letter of written) {
      type(typed.textContent + letter);
      await wait(letter === ' ' ? 45 : 25);
    }
    await wait(350);
    phone.dataset.sheet = 'sending';
    phone.dataset.state = 'analyzing';
    send.querySelector('.send-label').textContent = 'Analyzing';
    await wait(900);
    phone.dataset.sheet = '';
    phone.dataset.state = 'done';
    await count(days[2], days[3]);
    await wait(4000);
  }

  async function loop() {
    while (!reduced.matches) {
      reset();
      await wait(600);
      await viaChat();
      await viaVoice();
      await viaKeyboard();
    }
    settle();
  }

  new IntersectionObserver(([entry]) => (visible = entry.isIntersecting)).observe(
    phone.closest('.demos'),
  );

  if (reduced.matches) settle();
  else loop();

  for (const button of document.querySelectorAll('[data-copy]')) {
    button.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
        button.textContent = 'Copied';
      } catch {
        getSelection().selectAllChildren(button.previousElementSibling);
      }
      setTimeout(() => (button.textContent = 'Copy'), 1600);
    });
  }
})();
