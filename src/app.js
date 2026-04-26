require('dotenv').config();
const express    = require('express');
const cors       = require('cors');
const helmet     = require('helmet');
const morgan     = require('morgan');
const { connectDB } = require('./models/db');

const eaRoutes      = require('./routes/ea');
const tradeRoutes   = require('./routes/trades');
const signalRoutes  = require('./routes/signals');
const statusRoutes  = require('./routes/status');
const dashRoutes    = require('./routes/dashboard');

const app     = express();
const PORT    = process.env.PORT    || 7001;
const API_KEY = process.env.API_KEY || 'bmpt-secret-key-change-this';

// ========== CORS MUST BE FIRST - BEFORE ANY ROUTES ==========
// Allow specific origins
const allowedOrigins = [
  'http://localhost:4000',
  'http://localhost:3000',
  'http://127.0.0.1:4000',
  'http://127.0.0.1:3000'
];

// Configure CORS properly
app.use(cors({
  origin: function(origin, callback) {
    // Allow requests with no origin (like mobile apps, curl)
    if (!origin) return callback(null, true);
    
    if (allowedOrigins.indexOf(origin) !== -1) {
      callback(null, true);
    } else {
      console.log(`❌ CORS rejected origin: ${origin}`);
      callback(new Error('Not allowed by CORS'));
    }
  },
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS', 'PATCH'],
  allowedHeaders: ['Content-Type', 'X-API-Key', 'Authorization', 'Origin', 'Accept'],
  exposedHeaders: ['X-Total-Count'],
  maxAge: 86400,
  optionsSuccessStatus: 200
}));

// Handle preflight requests for all routes
app.options('*', (req, res) => {
  res.header('Access-Control-Allow-Origin', req.headers.origin || '*');
  res.header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS, PATCH');
  res.header('Access-Control-Allow-Headers', 'Content-Type, X-API-Key, Authorization');
  res.header('Access-Control-Allow-Credentials', 'true');
  res.sendStatus(200);
});

// Other middleware
app.use(helmet());
app.use(morgan('combined'));
app.use(express.json());

// Debug middleware to log all requests
app.use((req, res, next) => {
  console.log(`📡 ${req.method} ${req.path} - Origin: ${req.headers.origin || 'no-origin'}`);
  // Always set CORS headers for every response
  res.header('Access-Control-Allow-Origin', req.headers.origin || '*');
  res.header('Access-Control-Allow-Credentials', 'true');
  next();
});

// Auth middleware for all /api routes
app.use('/api', (req, res, next) => {
  const key = req.headers['x-api-key'] || req.query.apikey;
  if (key !== API_KEY) {
    console.log(`🔑 Auth failed for ${req.path} - Key: ${key}`);
    return res.status(401).json({ error: 'Unauthorised - Invalid API Key' });
  }
  next();
});

// Routes
app.use('/api/ea', eaRoutes);
app.use('/api/trades', tradeRoutes);
app.use('/api/signals', signalRoutes);
app.use('/api/status', statusRoutes);
app.use('/api/dashboard', dashRoutes);

// Public endpoints
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    db: 'mongodb',
    time: new Date().toISOString(),
    server: 'BMPT Trading Server v1.0'
  });
});

app.get('/', (req, res) => {
  res.json({
    name: 'BMPT Trading Server',
    db: 'MongoDB + Mongoose',
    version: '1.0.0',
    routes: [
      'GET  /health',
      'POST /api/ea/heartbeat',
      'POST /api/ea/signal',
      'POST /api/trades/open',
      'POST /api/trades/close',
      'GET  /api/trades/list',
      'GET  /api/trades/stats',
      'GET  /api/signals/latest',
      'GET  /api/signals/history',
      'GET  /api/status',
      'GET  /api/dashboard'
    ]
  });
});

// 404 handler
app.use('*', (req, res) => {
  res.status(404).json({ error: `Route not found: ${req.method} ${req.path}` });
});

// Error handler
app.use((err, req, res, next) => {
  console.error('❌ Error:', err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

// Connect to MongoDB then start server
connectDB().then(() => {
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`\n✅ BMPT Trading Server on port ${PORT}`);
    console.log(`   DB: ${process.env.MONGO_URI || 'mongodb://localhost:27017/bmpt'}`);
    console.log(`   Health: http://localhost:${PORT}/health`);
    console.log(`\n📡 CORS enabled for origins:`, allowedOrigins);
    console.log(`🔑 API Key required for all /api routes`);
    console.log(`\n🚀 Server ready for dashboard at http://localhost:4000\n`);
  });
}).catch(err => {
  console.error('❌ Failed to connect to MongoDB:', err.message);
  process.exit(1);
});

module.exports = app;