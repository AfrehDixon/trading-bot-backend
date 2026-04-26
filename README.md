# BMPT Trading Server — MongoDB Edition

## Database: MongoDB + Mongoose

```
Collections:
  heartbeats  → EA alive checks (auto-expires after 24h)
  trades      → Every trade opened/closed
  signals     → Every signal detected by EAs
```

---

## STEP 1 — Install MongoDB on VPS

```bash
# Ubuntu 22.04
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb.gpg
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list
apt-get update && apt-get install -y mongodb-org

# Start MongoDB
systemctl start mongod
systemctl enable mongod

# Verify
mongosh --eval "db.runCommand({ping:1})"
# Should show: { ok: 1 }
```

---

## STEP 2 — Upload and Deploy Server

```bash
# On your Mac — upload server folder
scp -r trading-server-mongo root@YOUR-VPS-IP:/root/trading-server

# On VPS
cd /root/trading-server
npm install

# Set your API key and Mongo URI
nano .env
# MONGO_URI=mongodb://localhost:27017/bmpt_trading
# API_KEY=bmpt-your-unique-key-here

# Test run
node src/app.js
# ✅ MongoDB connected
# ✅ BMPT Trading Server on port 3000

# Ctrl+C then use PM2
mkdir -p logs
pm2 start ecosystem.config.js
pm2 save && pm2 startup

# Open firewall
ufw allow 3000 && ufw enable
```

---

## STEP 3 — Test API

```bash
# Health check
curl http://YOUR-VPS-IP:3000/health

# Status (needs API key)
curl -H "X-Api-Key: bmpt-your-key" http://YOUR-VPS-IP:3000/api/status

# Dashboard
curl -H "X-Api-Key: bmpt-your-key" http://YOUR-VPS-IP:3000/api/dashboard
```

---

## STEP 4 — Install EAs in MT5

```bash
# On your Mac
BASE="/Users/dixonafreh/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts"

cp ~/Downloads/eas/EA1_PropFirmElite.mq5  "$BASE/"
cp ~/Downloads/eas/EA2_ScalpElite.mq5     "$BASE/"
cp ~/Downloads/eas/EA3_StepIndexElite.mq5 "$BASE/"
cp ~/Downloads/eas/EA4_SwingMaster.mq5    "$BASE/"
cp ~/Downloads/eas/EA5_UniversalHighWR.mq5"$BASE/"
```

In MetaEditor — edit each EA and set:
```
input string Server_URL = "http://YOUR-VPS-IP:3000";
input string API_Key    = "bmpt-your-unique-key-here";
```
Press F7 → 0 errors

In MT5 → Tools → Options → Expert Advisors:
- ✅ Allow WebRequest for listed URL
- Add: http://YOUR-VPS-IP:3000

---

## STEP 5 — Run Dashboard (Mac)

```bash
cd bmpt-dashboard
npm install
# Edit .env.local:
# NEXT_PUBLIC_API_URL=http://YOUR-VPS-IP:3000
# NEXT_PUBLIC_API_KEY=bmpt-your-unique-key-here
npm run dev
# Open: http://localhost:4000
```

---

## MongoDB Useful Commands

```bash
# Connect to mongo shell
mongosh

# Use your database
use bmpt_trading

# See all collections
show collections

# Count trades
db.trades.countDocuments()

# See recent trades
db.trades.find().sort({createdAt:-1}).limit(10).pretty()

# Win rate calculation
db.trades.aggregate([
  {$match:{status:"closed"}},
  {$group:{_id:null,wins:{$sum:{$cond:[{$gte:["$profit",0]},1,0]}},total:{$sum:1}}},
  {$addFields:{winRate:{$multiply:[{$divide:["$wins","$total"]},100]}}}
])

# See live EAs
db.heartbeats.find({createdAt:{$gt:new Date(Date.now()-300000)}}).pretty()

# Clear all trades (reset)
db.trades.deleteMany({})
```

---

## API Endpoints

All routes need header: `X-Api-Key: your-key`

```
GET  /health                  No auth
GET  /api/status              Server summary
GET  /api/dashboard           Full dashboard
GET  /api/ea/alive            Live EAs
GET  /api/trades/list         All trades
GET  /api/trades/stats        Win rate, profit
GET  /api/signals/latest      Signal history

POST /api/ea/heartbeat        EA alive ping
POST /api/ea/signal           EA found signal
POST /api/trades/open         Trade opened
POST /api/trades/close        Trade closed
```

---

## How Trades Execute

```
1. EA runs on MT5 (your laptop or VPS MT5)
2. EA scans market every bar (M5/M15/H1)
3. Signal found → EA places PENDING LIMIT in MT5
4. Price pulls back to limit → trade fills
5. EA posts to server: /api/trades/open
6. Trade runs to TP or SL
7. EA posts to server: /api/trades/close
8. Dashboard updates automatically

Server stores ALL history in MongoDB
Even if laptop goes offline, history is safe
When laptop reconnects, EAs resume reporting
```
