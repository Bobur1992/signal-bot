"""
TradingView -> Telegram Signal Bot
File: TradingView_to_Telegram_Signal_Bot.py

What this does:
- Runs a small Flask webhook server that accepts TradingView alerts (JSON POST)
- Validates a shared secret to avoid unauthorized posts
- Parses the alert payload (flexible: plain text or JSON) and sends a nicely-formatted
  message to a Telegram chat via a bot token
- Saves received signals to a local SQLite database (signal log)

How to use:
1) Install dependencies:
   pip install -r requirements.txt
   (requirements.txt contents are at the bottom of this file)

2) Create a Telegram bot (BotFather) and get the BOT_TOKEN. Get your chat_id (use /getUpdates or @userinfobot).

3) Configure environment variables before running (recommended):
   export TV_SECRET="your_shared_secret"       # secret TradingView will include in alert
   export TELEGRAM_BOT_TOKEN="123456:ABCDEF..."  
   export TELEGRAM_CHAT_ID="-1001234567890"     # or your personal chat id
   export HOSTNAME="https://your-server.com"    # used for testing/links (optional)

   Or fill the config dict below directly (not recommended for production).

4) In TradingView, create an alert and set the Webhook URL to:
   https://your-server.com/webhook
   and in the alert message put a JSON payload like the example below.

Example TradingView Alert Message (JSON):
{
  "secret": "your_shared_secret",
  "ticker": "XAUUSD",
  "exchange": "Forex",
  "action": "BUY",
  "price": "1995.40",
  "sl": "1991.00",
  "tp": "2002.00",
  "timeframe": "15m",
  "note": "EMA cross + RSI confirmation"
}

The server will accept either raw text or JSON. If you send plain text, put secret=... on first line.

---
Code follows:
"""

from flask import Flask, request, jsonify
import os
import requests
import sqlite3
from datetime import datetime
import threading
import json

# ------------------- Configuration -------------------
CONFIG = {
    # It's better to set these values as environment variables
    'TV_SECRET': os.environ.get('TV_SECRET', 'replace_with_real_secret'),
    'TELEGRAM_BOT_TOKEN': os.environ.get('TELEGRAM_BOT_TOKEN', ''),
    'TELEGRAM_CHAT_ID': os.environ.get('TELEGRAM_CHAT_ID', ''),
    'DB_PATH': os.environ.get('DB_PATH', 'signals.db'),
}

TELEGRAM_API = f"https://api.telegram.org/bot{CONFIG['TELEGRAM_BOT_TOKEN']}"

# ------------------- Simple DB -------------------
def init_db(db_path):
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute('''
        CREATE TABLE IF NOT EXISTS signals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            received_at TEXT,
            ticker TEXT,
            action TEXT,
            price TEXT,
            sl TEXT,
            tp TEXT,
            timeframe TEXT,
            raw_payload TEXT
        )
    ''')
    conn.commit()
    conn.close()

init_db(CONFIG['DB_PATH'])

# ------------------- Telegram helpers -------------------

def send_telegram_message(text, parse_mode='HTML'):
    """Send message to configured Telegram chat. Non-blocking."""
    if not CONFIG['TELEGRAM_BOT_TOKEN'] or not CONFIG['TELEGRAM_CHAT_ID']:
        print('Telegram not configured; skipping send.')
        return {'ok': False, 'error': 'telegram_not_configured'}

    url = f"{TELEGRAM_API}/sendMessage"
    payload = {
        'chat_id': CONFIG['TELEGRAM_CHAT_ID'],
        'text': text,
        'parse_mode': parse_mode,
        'disable_web_page_preview': True
    }

    try:
        r = requests.post(url, json=payload, timeout=10)
        return r.json()
    except Exception as e:
        print('Error sending telegram message:', e)
        return {'ok': False, 'error': str(e)}

# ------------------- Flask app -------------------
app = Flask(__name__)

def parse_tv_payload(req_text, req_json):
    """Try to parse the incoming TradingView webhook payload.
    Accepts either JSON (preferred) or free text.
    Returns a dict with keys: secret, ticker, action, price, sl, tp, timeframe, note, raw
    """
    result = {
        'secret': None,
        'ticker': None,
        'action': None,
        'price': None,
        'sl': None,
        'tp': None,
        'timeframe': None,
        'note': None,
        'raw': None
    }

    # 1) If JSON body provided by TradingView
    if req_json:
        try:
            # some TradingView users send the message as a string inside 'message'
            payload = req_json
            if 'message' in payload and isinstance(payload['message'], str):
                try:
                    payload_inner = json.loads(payload['message'])
                    payload.update(payload_inner)
                except Exception:
                    pass

            result.update({k: payload.get(k) for k in result.keys() if k in payload})
            result['raw'] = json.dumps(payload, ensure_ascii=False)
            return result
        except Exception:
            pass

    # 2) If plain text - try to parse lines like key: value
    text = req_text or ''
    result['raw'] = text
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    for line in lines:
        if ':' in line:
            k, v = [p.strip() for p in line.split(':', 1)]
            k_low = k.lower()
            if k_low in ['secret', 'pass', 'token']:
                result['secret'] = v
            elif k_low in ['ticker', 'symbol']:
                result['ticker'] = v
            elif k_low in ['action', 'side']:
                result['action'] = v.upper()
            elif k_low in ['price']:
                result['price'] = v
            elif k_low in ['sl']:
                result['sl'] = v
            elif k_low in ['tp']:
                result['tp'] = v
            elif k_low in ['timeframe', 'tf']:
                result['timeframe'] = v
            else:
                # append to note
                if result['note']:
                    result['note'] += ' | ' + line
                else:
                    result['note'] = line
        else:
            # line without colon — could be secret=... or just a message
            if '=' in line:
                k, v = [p.strip() for p in line.split('=', 1)]
                if k.lower() in ['secret', 'pass']:
                    result['secret'] = v
            else:
                if result['note']:
                    result['note'] += ' | ' + line
                else:
                    result['note'] = line
    return result

@app.route('/webhook', methods=['POST'])
def webhook():
    req_json = None
    try:
        req_json = request.get_json(silent=True)
    except Exception:
        req_json = None

    req_text = request.data.decode('utf-8', errors='ignore') if request.data else None

    parsed = parse_tv_payload(req_text, req_json)

    # verify secret
    tv_secret = parsed.get('secret')
    if not tv_secret or tv_secret != CONFIG['TV_SECRET']:
        return jsonify({'ok': False, 'error': 'invalid_secret'}), 403

    # build telegram message
    ticker = parsed.get('ticker') or 'Unknown'
    action = parsed.get('action') or 'SIGNAL'
    price = parsed.get('price') or ''
    sl = parsed.get('sl') or ''
    tp = parsed.get('tp') or ''
    tf = parsed.get('timeframe') or ''
    note = parsed.get('note') or ''

    message_lines = []
    message_lines.append(f"<b>{action} — {ticker}</b>")
    if tf:
        message_lines.append(f"Timeframe: <code>{tf}</code>")
    if price:
        message_lines.append(f"Price: <code>{price}</code>")
    if sl:
        message_lines.append(f"SL: <code>{sl}</code>")
    if tp:
        message_lines.append(f"TP: <code>{tp}</code>")
    if note:
        message_lines.append(f"Note: {note}")
    message_lines.append(f"Received: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')} UTC")

    message = "\n".join(message_lines)

    # send to telegram in a separate thread to keep webhook responsive
    threading.Thread(target=send_telegram_message, args=(message,)).start()

    # store in DB
    try:
        conn = sqlite3.connect(CONFIG['DB_PATH'])
        cur = conn.cursor()
        cur.execute('''
            INSERT INTO signals (received_at, ticker, action, price, sl, tp, timeframe, raw_payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', (datetime.utcnow().isoformat(), ticker, action, price, sl, tp, tf, parsed.get('raw')))
        conn.commit()
        conn.close()
    except Exception as e:
        print('DB error:', e)

    return jsonify({'ok': True})

@app.route('/')
def index():
    return 'TradingView -> Telegram Signal Bot is running.'

if __name__ == '__main__':
    # Use a production server (gunicorn/uvicorn) for deployment. For testing this is fine.
    app.run(host='0.0.0.0', port=5000)


# ------------------- requirements.txt (for reference) -------------------
# flask
# requests

# Save the above two lines into requirements.txt
