const supportLink = document.querySelector('[data-support]');
const dialog = document.querySelector('.support-dialog');
const mobileScreen = window.matchMedia('(max-width: 760px)');
const paymentURL = 'https://finance.ozon.ru/apps/sbp/ozonbankpay/fb932411-2764-4c38-9bb9-344feeb13dca';

if (supportLink && dialog) {
  function updateLink() {
    supportLink.href = mobileScreen.matches ? paymentURL : '/support/';
    if (mobileScreen.matches) {
      supportLink.removeAttribute('aria-haspopup');
    } else {
      supportLink.setAttribute('aria-haspopup', 'dialog');
    }
  }
  updateLink();
  mobileScreen.addEventListener('change', updateLink);

  supportLink.addEventListener('click', event => {
    if (mobileScreen.matches || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    if (typeof dialog.showModal !== 'function') return;
    event.preventDefault();
    dialog.showModal();
  });

  dialog.addEventListener('click', event => {
    if (event.target !== dialog) return;
    const bounds = dialog.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) {
      dialog.close();
    }
  });
}
