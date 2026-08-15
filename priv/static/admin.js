/* Earss Admin — progressive enhancement, no dependencies.
 *
 * Data-attribute driven:
 *   <input data-select-all="ids[]">          toggles all checkboxes named ids[]
 *   <form data-confirm="msg">                confirm() before submit
 *   <form data-confirm-select="action"
 *         data-confirm-value="unsubscribe"
 *         data-confirm-msg="...">            confirm when the named select
 *                                            holds the given value
 *   <button type="button" data-copy="text">  copy text to clipboard,
 *                                            flash "Copied" for 1.5s
 */
(function () {
  "use strict";

  function qsa(selector, fn) {
    Array.prototype.forEach.call(document.querySelectorAll(selector), fn);
  }

  /* select-all */
  qsa("input[data-select-all]", function (el) {
    el.addEventListener("change", function () {
      var name = el.getAttribute("data-select-all");
      qsa('input[name="' + name + '"]', function (cb) {
        cb.checked = el.checked;
      });
    });
  });

  /* plain confirm */
  qsa("form[data-confirm]", function (form) {
    form.addEventListener("submit", function (ev) {
      if (!window.confirm(form.getAttribute("data-confirm"))) {
        ev.preventDefault();
      }
    });
  });

  /* confirm on a specific submit button (multi-button forms) */
  qsa("button[data-confirm]", function (btn) {
    btn.addEventListener("click", function (ev) {
      if (!window.confirm(btn.getAttribute("data-confirm"))) {
        ev.preventDefault();
        ev.stopPropagation();
      }
    });
  });

  /* confirm when a select holds a value */
  qsa("form[data-confirm-select]", function (form) {
    form.addEventListener("submit", function (ev) {
      var name = form.getAttribute("data-confirm-select");
      var value = form.getAttribute("data-confirm-value");
      var msg = form.getAttribute("data-confirm-msg") || "Continue?";
      var sel = form.querySelector('select[name="' + name + '"]');
      if (sel && sel.value === value && !window.confirm(msg)) {
        ev.preventDefault();
      }
    });
  });

  /* copy to clipboard */
  function fallbackCopy(text) {
    var ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand("copy");
    } catch (e) {
      /* clipboard unavailable — silently keep the button label */
    }
    document.body.removeChild(ta);
  }

  qsa("button[data-copy]", function (btn) {
    btn.addEventListener("click", function () {
      var text = btn.getAttribute("data-copy");

      function done() {
        var original = btn.textContent;
        btn.textContent = "Copied";
        btn.disabled = true;
        setTimeout(function () {
          btn.textContent = original;
          btn.disabled = false;
        }, 1500);
      }

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () {
          fallbackCopy(text);
          done();
        });
      } else {
        fallbackCopy(text);
        done();
      }
    });
  });
})();
