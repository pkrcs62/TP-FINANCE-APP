/**
 * Investor Funding Management System â€” Backend (Google Apps Script)
 * ------------------------------------------------------------------
 * Deploy this as a Web App (Extensions > Apps Script > paste this file,
 * then Deploy > New deployment > Web app > Execute as: Me,
 * Who has access: Anyone with the link). Copy the resulting URL into
 * the HTML app's Settings screen.
 *
 * Sheet tabs required (created automatically on first run if missing):
 *   Investors     : id, name, address, mobile, remarks, status, createdAt
 *   Accounts      : id, accountNo, investorId, openingDate, openingAmount, roi, status, createdAt
 *   Transactions  : id, accountId, investorId, txnDate, txnType, amount,
 *                   balanceBefore, interestAdded, balanceAfter, remarks, createdAt
 *   AuditLog      : id, action, entity, entityId, details, createdAt
 *   Counters      : name, value   (used for INVST/account sequence numbers)
 *
 * Interest rule (frozen defaults, see Section 22 of spec):
 *   - 365-day year basis
 *   - Day count EXCLUDES the start date, INCLUDES the end date
 *     (i.e. days = endDate - startDate, in whole days)
 *   - Interest = balance * roi * days / 36500
 *   - Full precision kept internally; rounding only applied for display
 */

const SHEET_NAMES = {
  INVESTORS: 'Investors',
  ACCOUNTS: 'Accounts',
  TRANSACTIONS: 'Transactions',
  AUDIT: 'AuditLog',
  COUNTERS: 'Counters'
};

const HEADERS = {
  Investors: ['id', 'name', 'fatherName', 'address', 'mobile', 'remarks', 'status', 'createdAt'],
  Accounts: ['id', 'accountNo', 'investorId', 'openingDate', 'openingAmount', 'roi', 'status', 'createdAt'],
  Transactions: [
    'id', 'accountId', 'investorId', 'txnDate', 'txnType', 'amount',
    'balanceBefore', 'interestAdded', 'balanceAfter', 'remarks', 'createdAt',
    'receiptNo', 'paymentMode', 'chequeNo', 'chequeDate', 'drawnOnBank',
    'txnRefNo', 'narration', 'creditAccountNo', 'creditAccountName'
  ],
  AuditLog: ['id', 'action', 'entity', 'entityId', 'details', 'createdAt'],
  Counters: ['name', 'value']
};

// ---------- Web app entry points ----------

function doGet(e) {
  try {
    const action = e.parameter.action || 'getAll';
    let result;
    switch (action) {
      case 'getAll':
        result = getAllData();
        break;
      case 'ping':
        result = { ok: true, time: new Date().toISOString() };
        break;
      default:
        result = { error: 'Unknown GET action: ' + action };
    }
    return jsonOut(result);
  } catch (err) {
    return jsonOut({ error: err.message });
  }
}

function doPost(e) {
  try {
    const body = JSON.parse(e.postData.contents);
    const action = body.action;
    let result;
    switch (action) {
      case 'addInvestor':
        result = addInvestor(body.payload);
        break;
      case 'editInvestor':
        result = editInvestor(body.payload);
        break;
      case 'setInvestorStatus':
        result = setInvestorStatus(body.payload);
        break;
      case 'deleteInvestor':
        result = deleteInvestor(body.payload);
        break;
      case 'addInvestment':
        result = addInvestment(body.payload);
        break;
      case 'withdraw':
        result = withdraw(body.payload);
        break;
      case 'editTransaction':
        result = editTransaction(body.payload);
        break;
      case 'deleteTransaction':
        result = deleteTransaction(body.payload);
        break;
      case 'deleteAccount':
        result = deleteAccount(body.payload);
        break;
      case 'getAll':
        result = getAllData();
        break;
      case 'getReportAsOf':
        result = getReportAsOf(body.payload);
        break;
      default:
        result = { error: 'Unknown POST action: ' + action };
    }
    return jsonOut(result);
  } catch (err) {
    return jsonOut({ error: err.message });
  }
}

function jsonOut(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

// ---------- Sheet helpers ----------

function getSheet(name) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(name);
  if (!sh) {
    sh = ss.insertSheet(name);
    sh.appendRow(HEADERS[name]);
  } else if (sh.getLastRow() === 0) {
    sh.appendRow(HEADERS[name]);
  } else {
    ensureHeaders(sh, HEADERS[name]);
  }
  return sh;
}

// Adds any new columns (from the HEADERS constant) that don't yet exist
// in an already-deployed sheet, so older Sheets pick up new fields
// automatically without losing existing data or misaligning columns.
function ensureHeaders(sh, wantedHeaders) {
  const lastCol = sh.getLastColumn();
  const existing = sh.getRange(1, 1, 1, lastCol).getValues()[0];
  const missing = wantedHeaders.filter(h => existing.indexOf(h) === -1);
  if (missing.length) {
    sh.getRange(1, lastCol + 1, 1, missing.length).setValues([missing]);
  }
}

function readRows(name) {
  const sh = getSheet(name);
  const values = sh.getDataRange().getValues();
  if (values.length < 2) return [];
  const headers = values[0];
  const rows = [];
  for (let i = 1; i < values.length; i++) {
    const row = {};
    headers.forEach((h, idx) => { row[h] = values[i][idx]; });
    rows.push(row);
  }
  return rows;
}

// Writes obj's fields into the sheet's ACTUAL current header order
// (not just the HEADERS constant), so this stays safe even if a sheet
// was created before new columns were added.
function appendRow(name, obj) {
  const sh = getSheet(name);
  const lastCol = sh.getLastColumn();
  const actualHeaders = sh.getRange(1, 1, 1, lastCol).getValues()[0];
  const row = actualHeaders.map(h => (obj[h] !== undefined ? obj[h] : ''));
  sh.appendRow(row);
}

function updateRowById(name, id, updates) {
  const sh = getSheet(name);
  const values = sh.getDataRange().getValues();
  const headers = values[0];
  const idCol = headers.indexOf('id');
  for (let i = 1; i < values.length; i++) {
    if (String(values[i][idCol]) === String(id)) {
      Object.keys(updates).forEach(key => {
        const col = headers.indexOf(key);
        if (col !== -1) sh.getRange(i + 1, col + 1).setValue(updates[key]);
      });
      return true;
    }
  }
  return false;
}

// Deletes the row matching id. Returns the deleted row's data (as an
// object) so the caller can log it, or null if not found.
function deleteRowById(name, id) {
  const sh = getSheet(name);
  const values = sh.getDataRange().getValues();
  const headers = values[0];
  const idCol = headers.indexOf('id');
  for (let i = 1; i < values.length; i++) {
    if (String(values[i][idCol]) === String(id)) {
      const row = {};
      headers.forEach((h, idx) => { row[h] = values[i][idx]; });
      sh.deleteRow(i + 1);
      return row;
    }
  }
  return null;
}


function nextCounter(name) {
  const sh = getSheet(SHEET_NAMES.COUNTERS);
  const values = sh.getDataRange().getValues();
  for (let i = 1; i < values.length; i++) {
    if (values[i][0] === name) {
      const next = Number(values[i][1]) + 1;
      sh.getRange(i + 1, 2).setValue(next);
      return next;
    }
  }
  sh.appendRow([name, 1]);
  return 1;
}

function logAudit(action, entity, entityId, details) {
  appendRow(SHEET_NAMES.AUDIT, {
    id: Utilities.getUuid(),
    action: action,
    entity: entity,
    entityId: entityId,
    details: typeof details === 'string' ? details : JSON.stringify(details),
    createdAt: new Date().toISOString()
  });
}

// ---------- Interest engine ----------
// days = whole days between startDate (exclusive) and endDate (inclusive)
function daysBetween(startDate, endDate) {
  const start = new Date(startDate);
  const end = new Date(endDate);
  const msPerDay = 24 * 60 * 60 * 1000;
  const days = Math.round((end.getTime() - start.getTime()) / msPerDay);
  return Math.max(days, 0);
}

function calcInterest(balance, roiPercent, days) {
  return (balance * roiPercent * days) / 36500;
}

// ---------- Investor operations ----------

function addInvestor(p) {
  const seq = nextCounter('investor');
  const id = 'INVST' + String(seq).padStart(2, '0');
  const record = {
    id: id,
    name: p.name,
    fatherName: p.fatherName || '',
    address: p.address || '',
    mobile: p.mobile,
    remarks: p.remarks || '',
    status: 'ACTIVE',
    createdAt: new Date().toISOString()
  };
  appendRow(SHEET_NAMES.INVESTORS, record);
  logAudit('CREATE', 'Investor', id, record);
  return { ok: true, investor: record };
}

function editInvestor(p) {
  const updates = {};
  ['name', 'fatherName', 'address', 'mobile', 'remarks'].forEach(k => {
    if (p[k] !== undefined) updates[k] = p[k];
  });
  const success = updateRowById(SHEET_NAMES.INVESTORS, p.id, updates);
  if (!success) return { error: 'Investor not found' };
  logAudit('EDIT', 'Investor', p.id, updates);
  return { ok: true };
}

function setInvestorStatus(p) {
  const success = updateRowById(SHEET_NAMES.INVESTORS, p.id, { status: p.status });
  if (!success) return { error: 'Investor not found' };
  logAudit('STATUS_CHANGE', 'Investor', p.id, { status: p.status });
  return { ok: true };
}

// Always allowed (per current business decision), regardless of
// transaction history. The caller (frontend) is responsible for
// warning the admin first when history exists â€” this function itself
// does not block on that, it just executes the delete and logs it.
// Deletes the investor record; their accounts/transactions remain in
// the Accounts/Transactions sheets as orphaned historical rows (not
// auto-deleted) so the underlying financial data isn't destroyed even
// though the investor master record is gone.
function deleteInvestor(p) {
  const deleted = deleteRowById(SHEET_NAMES.INVESTORS, p.id);
  if (!deleted) return { error: 'Investor not found' };
  logAudit('DELETE', 'Investor', p.id, deleted);
  return { ok: true };
}

// ---------- Investment / Account operations ----------

function nextReceiptNo() {
  const seq = nextCounter('receipt');
  return 'TPF-' + String(seq).padStart(4, '0');
}

// p: investorId, amount, date (ISO), roi, remarks,
//    topUpAccountId (optional â€” if set, adds to this existing account
//    instead of creating a new one),
//    paymentMode, chequeNo, chequeDate, drawnOnBank, txnRefNo,
//    narration, creditAccountNo, creditAccountName
function addInvestment(p) {
  const investors = readRows(SHEET_NAMES.INVESTORS);
  const investor = investors.find(inv => String(inv.id) === String(p.investorId));
  if (!investor) return { error: 'Investor not found' };

  const paymentFields = {
    receiptNo: nextReceiptNo(),
    paymentMode: p.paymentMode || '',
    chequeNo: p.chequeNo || '',
    chequeDate: p.chequeDate || '',
    drawnOnBank: p.drawnOnBank || '',
    txnRefNo: p.txnRefNo || '',
    narration: p.narration || '',
    creditAccountNo: p.creditAccountNo || '',
    creditAccountName: p.creditAccountName || ''
  };

  // ---- Top-up mode: add funds to an existing account (same ROI) ----
  if (p.topUpAccountId) {
    const accounts = readRows(SHEET_NAMES.ACCOUNTS);
    const account = accounts.find(a => String(a.id) === String(p.topUpAccountId));
    if (!account) return { error: 'Account to top up was not found' };
    if (account.status === 'CLOSED') return { error: 'Cannot add funds to a closed account' };
    if (String(account.investorId) !== String(p.investorId)) return { error: 'Account does not belong to this investor' };

    const transactions = readRows(SHEET_NAMES.TRANSACTIONS);
    const valuation = computeAccountValue(account, transactions, p.date);
    const addAmount = Number(p.amount);
    const newBalance = valuation.currentValue + addAmount;

    const txn = Object.assign({
      id: Utilities.getUuid(),
      accountId: account.id,
      investorId: p.investorId,
      txnDate: p.date,
      txnType: 'TOPUP',
      amount: addAmount,
      balanceBefore: valuation.runningBalance,
      interestAdded: valuation.accruedInterest,
      balanceAfter: newBalance,
      remarks: p.remarks || '',
      createdAt: new Date().toISOString()
    }, paymentFields);
    appendRow(SHEET_NAMES.TRANSACTIONS, txn);

    logAudit('TOPUP', 'Account', account.id, txn);
    return { ok: true, account: account, transaction: txn, topUp: true };
  }

  // ---- Normal mode: create a brand-new account ----
  const accounts = readRows(SHEET_NAMES.ACCOUNTS);
  const existingForInvestor = accounts.filter(a => String(a.investorId) === String(p.investorId));
  const seq = existingForInvestor.length + 1;
  const accountNo = p.investorId + '-' + String(seq).padStart(3, '0');

  const account = {
    id: Utilities.getUuid(),
    accountNo: accountNo,
    investorId: p.investorId,
    openingDate: p.date,
    openingAmount: Number(p.amount),
    roi: Number(p.roi),
    status: 'ACTIVE',
    createdAt: new Date().toISOString()
  };
  appendRow(SHEET_NAMES.ACCOUNTS, account);

  const txn = Object.assign({
    id: Utilities.getUuid(),
    accountId: account.id,
    investorId: p.investorId,
    txnDate: p.date,
    txnType: 'INVESTMENT',
    amount: Number(p.amount),
    balanceBefore: 0,
    interestAdded: 0,
    balanceAfter: Number(p.amount),
    remarks: p.remarks || '',
    createdAt: new Date().toISOString()
  }, paymentFields);
  appendRow(SHEET_NAMES.TRANSACTIONS, txn);

  logAudit('CREATE', 'Account', account.id, account);
  return { ok: true, account: account, transaction: txn, topUp: false };
}

// Computes current running balance, last event date, and accrued interest
// as of a given as-on date, for one account.
function computeAccountValue(account, transactions, asOnDate) {
  const accTxns = transactions
    .filter(t => String(t.accountId) === String(account.id))
    .sort((a, b) => new Date(a.txnDate) - new Date(b.txnDate));

  let balance = 0;
  let lastDate = account.openingDate;

  accTxns.forEach(t => {
    balance = Number(t.balanceAfter);
    lastDate = t.txnDate;
  });

  const asOn = asOnDate || new Date().toISOString();
  const days = daysBetween(lastDate, asOn);
  const accruedInterest = calcInterest(balance, Number(account.roi), days);
  const currentValue = balance + accruedInterest;

  return {
    runningBalance: balance,
    lastEventDate: lastDate,
    daysSinceLastEvent: days,
    accruedInterest: accruedInterest,
    currentValue: currentValue
  };
}

// ---------- Recalculation engine ----------
// Replays ALL of an account's transactions in chronological (txnDate,
// then createdAt as tiebreaker) order and rewrites balanceBefore /
// interestAdded / balanceAfter for every transaction on the Sheet.
// Used after any edit or delete to an account's transaction, per the
// spec's backdated-transaction recalculation requirement (Section 13).
// Also recomputes and updates the account's status (CLOSED if the
// last transaction was a FULL_SETTLEMENT that zeroed it out, else
// ACTIVE) since deleting a settlement should reopen the account.
function recalculateAccount(accountId) {
  const account = readRows(SHEET_NAMES.ACCOUNTS).find(a => String(a.id) === String(accountId));
  if (!account) return { error: 'Account not found for recalculation' };

  const allTxns = readRows(SHEET_NAMES.TRANSACTIONS);
  const accTxns = allTxns
    .filter(t => String(t.accountId) === String(accountId))
    .sort((a, b) => new Date(a.txnDate) - new Date(b.txnDate) || new Date(a.createdAt) - new Date(b.createdAt));

  let balance = 0;
  let lastDate = account.openingDate;
  let finalStatus = 'ACTIVE';

  accTxns.forEach(t => {
    const days = daysBetween(lastDate, t.txnDate);
    const interest = calcInterest(balance, Number(account.roi), days);
    const balanceBefore = balance + interest;

    let balanceAfter;
    if (t.txnType === 'INVESTMENT') {
      // Opening transaction: balance starts fresh at the invested amount
      balanceAfter = Number(t.amount);
      finalStatus = 'ACTIVE';
    } else if (t.txnType === 'TOPUP') {
      balanceAfter = balanceBefore + Number(t.amount);
      finalStatus = 'ACTIVE';
    } else if (t.txnType === 'FULL_SETTLEMENT') {
      balanceAfter = 0;
      finalStatus = 'CLOSED';
    } else { // WITHDRAWAL
      balanceAfter = balanceBefore - Number(t.amount);
      finalStatus = 'ACTIVE';
    }

    updateRowById(SHEET_NAMES.TRANSACTIONS, t.id, {
      balanceBefore: t.txnType === 'INVESTMENT' ? 0 : balanceBefore,
      interestAdded: t.txnType === 'INVESTMENT' ? 0 : interest,
      balanceAfter: balanceAfter
    });

    balance = balanceAfter;
    lastDate = t.txnDate;
  });

  updateRowById(SHEET_NAMES.ACCOUNTS, accountId, { status: finalStatus });
  return { ok: true };
}

// ---------- Edit / Delete a transaction ----------
// p: id (transaction id), plus any editable fields: txnDate, amount,
//    remarks, paymentMode, chequeNo, chequeDate, drawnOnBank,
//    txnRefNo, narration, creditAccountNo, creditAccountName.
// ROI is intentionally NOT editable here â€” it belongs to the account,
// not a single transaction, per the one-ROI-per-account rule.
function editTransaction(p) {
  const txns = readRows(SHEET_NAMES.TRANSACTIONS);
  const txn = txns.find(t => String(t.id) === String(p.id));
  if (!txn) return { error: 'Transaction not found' };

  const updates = {};
  const editableFields = ['txnDate', 'amount', 'remarks', 'paymentMode', 'chequeNo',
    'chequeDate', 'drawnOnBank', 'txnRefNo', 'narration', 'creditAccountNo', 'creditAccountName'];
  editableFields.forEach(f => { if (p[f] !== undefined) updates[f] = p[f]; });

  if (updates.amount !== undefined && Number(updates.amount) <= 0) {
    return { error: 'Amount must be greater than zero' };
  }

  const success = updateRowById(SHEET_NAMES.TRANSACTIONS, p.id, updates);
  if (!success) return { error: 'Transaction not found' };

  const recalc = recalculateAccount(txn.accountId);
  if (recalc.error) return recalc;

  logAudit('EDIT', 'Transaction', p.id, updates);
  return { ok: true };
}

// p: id (transaction id). If the deleted transaction was the account's
// only INVESTMENT (opening) transaction, the account itself is left
// in place but with no transactions â€” recalculation will simply show
// zero balance; the account is not auto-deleted.
function deleteTransaction(p) {
  const deleted = deleteRowById(SHEET_NAMES.TRANSACTIONS, p.id);
  if (!deleted) return { error: 'Transaction not found' };

  const recalc = recalculateAccount(deleted.accountId);
  if (recalc.error) return recalc;

  logAudit('DELETE', 'Transaction', p.id, deleted);
  return { ok: true };
}

// ---------- Delete an account ----------
// Always allowed (matching the investor-delete decision). Deletes the
// account record; its transactions remain in the Transactions sheet
// as orphaned historical rows (not auto-deleted), same approach as
// deleteInvestor, so underlying financial data isn't destroyed even
// though the account master record is gone.
function deleteAccount(p) {
  const deleted = deleteRowById(SHEET_NAMES.ACCOUNTS, p.id);
  if (!deleted) return { error: 'Account not found' };
  logAudit('DELETE', 'Account', p.id, deleted);
  return { ok: true };
}

function withdraw(p) {
  // p: accountId, date (ISO), amount, remarks
  const accounts = readRows(SHEET_NAMES.ACCOUNTS);
  const account = accounts.find(a => String(a.id) === String(p.accountId));
  if (!account) return { error: 'Account not found' };
  if (account.status === 'CLOSED') return { error: 'Account is already closed' };

  const transactions = readRows(SHEET_NAMES.TRANSACTIONS);
  const valuation = computeAccountValue(account, transactions, p.date);

  const withdrawAmount = Number(p.amount);
  if (withdrawAmount <= 0) return { error: 'Withdrawal amount must be greater than zero' };
  if (withdrawAmount > valuation.currentValue + 0.01) {
    return { error: 'Withdrawal amount exceeds available value (Rs. ' + valuation.currentValue.toFixed(2) + ')' };
  }

  const balanceAfter = valuation.currentValue - withdrawAmount;
  const isFullSettlement = p.fullSettlement === true || balanceAfter < 0.01;

  const txn = {
    id: Utilities.getUuid(),
    accountId: account.id,
    investorId: account.investorId,
    txnDate: p.date,
    txnType: isFullSettlement ? 'FULL_SETTLEMENT' : 'WITHDRAWAL',
    amount: withdrawAmount,
    balanceBefore: valuation.runningBalance,
    interestAdded: valuation.accruedInterest,
    balanceAfter: isFullSettlement ? 0 : balanceAfter,
    remarks: p.remarks || '',
    createdAt: new Date().toISOString()
  };
  appendRow(SHEET_NAMES.TRANSACTIONS, txn);

  if (isFullSettlement) {
    updateRowById(SHEET_NAMES.ACCOUNTS, account.id, { status: 'CLOSED' });
  }

  logAudit(isFullSettlement ? 'FULL_SETTLEMENT' : 'WITHDRAWAL', 'Account', account.id, txn);
  return { ok: true, transaction: txn, accountClosed: isFullSettlement };
}

// ---------- Aggregate fetch for the frontend ----------

function getAllData() {
  const investors = readRows(SHEET_NAMES.INVESTORS);
  const accounts = readRows(SHEET_NAMES.ACCOUNTS);
  const transactions = readRows(SHEET_NAMES.TRANSACTIONS);

  const asOnDate = new Date().toISOString();
  const accountsWithValue = accounts.map(acc => {
    const val = computeAccountValue(acc, transactions, asOnDate);
    return Object.assign({}, acc, val);
  });

  return {
    ok: true,
    asOnDate: asOnDate,
    investors: investors,
    accounts: accountsWithValue,
    transactions: transactions
  };
}

// ---------- As-on-date reporting ----------
// Unlike computeAccountValue (used by the live dashboard, which always
// uses the latest transaction regardless of date), this replays only
// transactions that occurred on or before the cutoff date â€” giving a
// true historical position as required by Section 12 of the spec.
function computeAccountValueAsOf(account, transactions, asOnDate) {
  const cutoff = new Date(asOnDate);
  const accTxns = transactions
    .filter(t => String(t.accountId) === String(account.id))
    .filter(t => new Date(t.txnDate) <= cutoff)
    .sort((a, b) => new Date(a.txnDate) - new Date(b.txnDate) || new Date(a.createdAt) - new Date(b.createdAt));

  // Was the account even opened yet as of this date?
  if (new Date(account.openingDate) > cutoff) {
    return null; // account did not exist yet as of the cutoff
  }

  let balance = 0;
  let lastDate = account.openingDate;
  let closedAsOf = false;

  accTxns.forEach(t => {
    balance = Number(t.balanceAfter);
    lastDate = t.txnDate;
    if (t.txnType === 'FULL_SETTLEMENT') closedAsOf = true;
  });

  const days = daysBetween(lastDate, asOnDate);
  const accruedInterest = closedAsOf ? 0 : calcInterest(balance, Number(account.roi), days);
  const currentValue = balance + accruedInterest;

  return {
    runningBalance: balance,
    lastEventDate: lastDate,
    daysSinceLastEvent: days,
    accruedInterest: accruedInterest,
    currentValue: currentValue,
    statusAsOf: closedAsOf ? 'CLOSED' : 'ACTIVE',
    transactionsAsOf: accTxns
  };
}

// action: getReportAsOf
// payload: { asOnDate: ISO date string, investorId: optional (omit for all investors) }
function getReportAsOf(p) {
  const asOnDate = p.asOnDate || new Date().toISOString();
  const investors = readRows(SHEET_NAMES.INVESTORS);
  const accounts = readRows(SHEET_NAMES.ACCOUNTS);
  const transactions = readRows(SHEET_NAMES.TRANSACTIONS);

  const relevantInvestors = p.investorId
    ? investors.filter(i => String(i.id) === String(p.investorId))
    : investors;

  const report = relevantInvestors.map(inv => {
    const invAccounts = accounts.filter(a => String(a.investorId) === String(inv.id));
    const accountRows = invAccounts
      .map(acc => {
        const val = computeAccountValueAsOf(acc, transactions, asOnDate);
        if (!val) return null; // not opened yet as of this date
        return Object.assign({}, acc, val);
      })
      .filter(a => a !== null);

    const totalRunningBalance = accountRows.reduce((s, a) => s + a.runningBalance, 0);
    const totalAccruedInterest = accountRows.reduce((s, a) => s + a.accruedInterest, 0);
    const totalCurrentValue = accountRows.reduce((s, a) => s + a.currentValue, 0);

    return {
      investor: inv,
      accounts: accountRows,
      totals: {
        runningBalance: totalRunningBalance,
        accruedInterest: totalAccruedInterest,
        currentValue: totalCurrentValue
      }
    };
  });

  const grandTotals = report.reduce((g, r) => ({
    runningBalance: g.runningBalance + r.totals.runningBalance,
    accruedInterest: g.accruedInterest + r.totals.accruedInterest,
    currentValue: g.currentValue + r.totals.currentValue
  }), { runningBalance: 0, accruedInterest: 0, currentValue: 0 });

  return {
    ok: true,
    asOnDate: asOnDate,
    report: report,
    grandTotals: grandTotals
  };
}
