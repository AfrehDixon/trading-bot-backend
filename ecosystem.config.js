module.exports = {
  apps: [{
    name:        'trading-server',
    script:      'src/app.js',
    instances:   1,
    autorestart: true,
    watch:       false,
    max_memory_restart: '200M',
    env: {
      NODE_ENV: 'production',
      PORT:     7001
    },
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
    error_file:  './logs/error.log',
    out_file:    './logs/out.log',
    merge_logs:  true
  }]
};
