// Data loaded from embedded JSON
const transactions = JSON.parse(document.getElementById("tx-data").textContent);
const accounts = JSON.parse(document.getElementById("accounts-data").textContent);

// --- Status bar ---

const statusBar = document.getElementById("status-bar");
let statusTimeout;

function showStatus(message, type = "success") {
  statusBar.textContent = message;
  statusBar.className = "status-bar " + type;
  clearTimeout(statusTimeout);
  statusTimeout = setTimeout(() => {
    statusBar.className = "status-bar hidden";
  }, 3000);
}

// --- Progress tracking ---

function updateProgress() {
  const rows = document.querySelectorAll(".tx-row");
  let complete = 0;
  const total = rows.length;

  rows.forEach((row) => {
    const account = row.querySelector('[data-field="expense_account"]').value.trim();

    if (account) {
      row.classList.add("complete");
      row.classList.remove("incomplete");
      complete++;
    } else {
      row.classList.remove("complete");
      row.classList.add("incomplete");
    }
  });

  document.getElementById("progress").textContent = complete + "/" + total + " complete";
}

// --- Collect current state from DOM ---

function collectTransactions() {
  const rows = document.querySelectorAll(".tx-row");
  const updated = [...transactions];

  rows.forEach((row) => {
    const index = parseInt(row.dataset.index, 10);
    const tx = updated[index];
    tx.payee = row.querySelector('[data-field="payee"]').value.trim() || null;
    tx.narration = row.querySelector('[data-field="narration"]').value.trim() || null;
    tx.expense_account = row.querySelector('[data-field="expense_account"]').value.trim() || null;
  });

  return updated;
}

// --- Save actions ---

async function saveAndReload(url, method, successMsg) {
  try {
    const res = await fetch(url, {
      method: method,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ transactions: collectTransactions() }),
    });
    const data = await res.json();
    showStatus(successMsg);
    // Reload after a brief pause so the user sees the status message
    setTimeout(() => window.location.reload(), 400);
    return data;
  } catch (e) {
    showStatus("Error: " + e.message, "error");
  }
}

function saveJSON() {
  return saveAndReload("/transactions", "PUT", "Saved JSON");
}

function saveAndConvert() {
  return saveAndReload("/convert", "POST", "Saved & converted");
}

function saveConvertAndMerge() {
  return saveAndReload("/convert-and-merge", "POST", "Saved, converted & merged");
}

// --- Button handlers ---

document.getElementById("btn-save").addEventListener("click", saveJSON);
document.getElementById("btn-convert").addEventListener("click", saveAndConvert);
document.getElementById("btn-merge").addEventListener("click", saveConvertAndMerge);

// --- Keyboard shortcuts ---

document.addEventListener("keydown", (e) => {
  const mod = e.metaKey || e.ctrlKey;

  // Cmd+S / Ctrl+S — save JSON
  if (mod && !e.shiftKey && e.key === "s") {
    e.preventDefault();
    saveJSON();
  }

  // Cmd+Shift+S / Ctrl+Shift+S — save, convert & merge
  if (mod && e.shiftKey && e.key === "S") {
    e.preventDefault();
    saveConvertAndMerge();
  }

  // Cmd+Shift+C / Ctrl+Shift+C — save & convert
  if (mod && e.shiftKey && e.key === "C") {
    e.preventDefault();
    saveAndConvert();
  }
});

// --- Autocomplete for expense accounts ---

const dropdown = document.createElement("div");
dropdown.className = "autocomplete-dropdown hidden";
document.body.appendChild(dropdown);

let activeInput = null;
let selectedIndex = -1;
let filteredAccounts = [];

function positionDropdown(input) {
  const rect = input.getBoundingClientRect();
  dropdown.style.minWidth = rect.width + "px";
  dropdown.style.top = rect.bottom + window.scrollY + 2 + "px";
  // Align to right edge of input so it doesn't overflow the viewport
  dropdown.style.right = (document.documentElement.clientWidth - rect.right - window.scrollX) + "px";
  dropdown.style.left = "auto";
}

function showDropdown(input, query) {
  activeInput = input;
  const q = query.toLowerCase();
  filteredAccounts = q
    ? accounts.filter((a) => a.toLowerCase().includes(q))
    : accounts.slice(0, 20);

  if (filteredAccounts.length === 0) {
    hideDropdown();
    return;
  }

  selectedIndex = -1;
  dropdown.innerHTML = filteredAccounts
    .slice(0, 20)
    .map((a, i) => {
      const highlighted = q ? highlightMatch(a, q) : a;
      return '<div class="autocomplete-item" data-index="' + i + '">' + highlighted + "</div>";
    })
    .join("");

  positionDropdown(input);
  dropdown.classList.remove("hidden");
}

function highlightMatch(text, query) {
  const idx = text.toLowerCase().indexOf(query);
  if (idx === -1) return text;
  return (
    text.slice(0, idx) +
    "<strong>" +
    text.slice(idx, idx + query.length) +
    "</strong>" +
    text.slice(idx + query.length)
  );
}

function hideDropdown() {
  dropdown.classList.add("hidden");
  activeInput = null;
  selectedIndex = -1;
  filteredAccounts = [];
}

function selectItem(index) {
  if (!activeInput || index < 0 || index >= filteredAccounts.length) return;
  activeInput.value = filteredAccounts[index];
  hideDropdown();
  updateProgress();
}

function updateSelection() {
  dropdown.querySelectorAll(".autocomplete-item").forEach((el, i) => {
    el.classList.toggle("selected", i === selectedIndex);
  });
  const selected = dropdown.querySelector(".autocomplete-item.selected");
  if (selected) selected.scrollIntoView({ block: "nearest" });
}

// Attach to all expense_account inputs
document.querySelectorAll('[data-field="expense_account"]').forEach((input) => {
  input.addEventListener("input", () => {
    showDropdown(input, input.value.trim());
  });

  input.addEventListener("focus", () => {
    if (input.value.trim()) {
      showDropdown(input, input.value.trim());
    }
  });

  input.addEventListener("keydown", (e) => {
    if (dropdown.classList.contains("hidden")) return;

    if (e.key === "ArrowDown") {
      e.preventDefault();
      selectedIndex = Math.min(selectedIndex + 1, Math.min(filteredAccounts.length, 20) - 1);
      updateSelection();
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      selectedIndex = Math.max(selectedIndex - 1, 0);
      updateSelection();
    } else if (e.key === "Enter") {
      if (selectedIndex >= 0) {
        e.preventDefault();
        selectItem(selectedIndex);
      }
    } else if (e.key === "Escape") {
      hideDropdown();
    }
  });

  input.addEventListener("blur", () => {
    // Delay to allow click on dropdown item
    setTimeout(hideDropdown, 150);
  });
});

// Click on dropdown items
dropdown.addEventListener("mousedown", (e) => {
  const item = e.target.closest(".autocomplete-item");
  if (item) {
    e.preventDefault();
    selectItem(parseInt(item.dataset.index, 10));
  }
});

// --- Track changes for progress ---

document.querySelectorAll(".tx-row input").forEach((input) => {
  input.addEventListener("input", updateProgress);
});

// --- Init ---

updateProgress();

// Focus the first empty input
const firstEmpty = document.querySelector('.tx-row input[value=""]') ||
                   document.querySelector(".tx-row input:not([value])");
if (firstEmpty) firstEmpty.focus();
