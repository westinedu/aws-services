// 加密货币行情网站主要JavaScript逻辑

// 模拟加密货币数据
const cryptoData = {
    BTC: {
        name: 'Bitcoin',
        symbol: 'BTC',
        price: 112384.50,
        change24h: 2.34,
        marketCap: 2355500000000,
        volume24h: 45800000000,
        icon: 'resources/bitcoin-icon.png',
        history: []
    },
    ETH: {
        name: 'Ethereum',
        symbol: 'ETH',
        price: 4091.20,
        change24h: -1.23,
        marketCap: 435000000000,
        volume24h: 32100000000,
        icon: 'resources/ethereum-icon.png',
        history: []
    },
    XRP: {
        name: 'XRP',
        symbol: 'XRP',
        price: 2.85,
        change24h: 5.67,
        marketCap: 192000000000,
        volume24h: 8900000000,
        icon: '',
        history: []
    },
    BNB: {
        name: 'BNB',
        symbol: 'BNB',
        price: 1478.30,
        change24h: 1.89,
        marketCap: 108000000000,
        volume24h: 5600000000,
        icon: '',
        history: []
    },
    SOL: {
        name: 'Solana',
        symbol: 'SOL',
        price: 198.45,
        change24h: -3.45,
        marketCap: 102000000000,
        volume24h: 4300000000,
        icon: '',
        history: []
    },
    ADA: {
        name: 'Cardano',
        symbol: 'ADA',
        price: 0.85,
        change24h: 2.15,
        marketCap: 30000000000,
        volume24h: 1200000000,
        icon: '',
        history: []
    },
    DOGE: {
        name: 'Dogecoin',
        symbol: 'DOGE',
        price: 0.32,
        change24h: 8.92,
        marketCap: 37000000000,
        volume24h: 2100000000,
        icon: '',
        history: []
    },
    TRX: {
        name: 'TRON',
        symbol: 'TRX',
        price: 0.28,
        change24h: -1.78,
        marketCap: 29000000000,
        volume24h: 1500000000,
        icon: '',
        history: []
    }
};

// 交易所数据
const exchangeData = [
    {
        name: 'Binance',
        volume24h: 28500000000,
        pairs: 1850,
        countries: 'Global',
        founded: 2017,
        fee: 0.1,
        security: 9.5,
        logo: '',
        features: ['Low Fees', 'High Liquidity', 'Futures Trading']
    },
    {
        name: 'Coinbase',
        volume24h: 4200000000,
        pairs: 290,
        countries: 'US, EU, UK',
        founded: 2012,
        fee: 0.5,
        security: 9.8,
        logo: '',
        features: ['Regulated', 'Beginner Friendly', 'Insurance']
    },
    {
        name: 'Kraken',
        volume24h: 2100000000,
        pairs: 410,
        countries: 'Global',
        founded: 2011,
        fee: 0.25,
        security: 9.7,
        logo: '',
        features: ['High Security', 'Staking', 'Futures']
    },
    {
        name: 'OKX',
        volume24h: 3200000000,
        pairs: 720,
        countries: 'Global',
        founded: 2017,
        fee: 0.08,
        security: 9.2,
        logo: '',
        features: ['DeFi Integration', 'Options', 'Web3 Wallet']
    }
];

// 全局变量
let currentCoin = 'BTC';
let comparisonCoins = ['BTC', 'ETH'];
let priceChart = null;
let comparisonChart = null;

// 工具函数
function formatPrice(price) {
    return new Intl.NumberFormat('en-US', {
        style: 'currency',
        currency: 'USD',
        minimumFractionDigits: 2,
        maximumFractionDigits: 2
    }).format(price);
}

function formatMarketCap(marketCap) {
    if (marketCap >= 1e12) {
        return `$${(marketCap / 1e12).toFixed(2)}T`;
    } else if (marketCap >= 1e9) {
        return `$${(marketCap / 1e9).toFixed(2)}B`;
    } else if (marketCap >= 1e6) {
        return `$${(marketCap / 1e6).toFixed(2)}M`;
    }
    return `$${marketCap.toLocaleString()}`;
}

function formatVolume(volume) {
    return formatMarketCap(volume);
}

// 更新交易所列表显示
function updateExchangeList() {
    const container = document.getElementById('exchange-list');
    if (!container) return;

    container.innerHTML = '';
    
    exchangeData.forEach(exchange => {
        const exchangeElement = document.createElement('div');
        exchangeElement.className = 'exchange-card bg-gray-800 rounded-xl p-6 card-glow';
        exchangeElement.innerHTML = `
            <div class="flex items-center justify-between mb-4">
                <h3 class="text-xl font-bold text-white">${exchange.name}</h3>
                <div class="security-score rounded-lg px-3 py-1">
                    <span class="text-green-400 font-bold">${exchange.security}/10</span>
                </div>
            </div>
            
            <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
                <div>
                    <div class="text-gray-400 text-sm mb-1">24h交易量</div>
                    <div class="text-white font-bold text-lg">${formatVolume(exchange.volume24h)}</div>
                </div>
                <div>
                    <div class="text-gray-400 text-sm mb-1">交易对</div>
                    <div class="text-white font-bold text-lg">${exchange.pairs.toLocaleString()}</div>
                </div>
                <div>
                    <div class="text-gray-400 text-sm mb-1">手续费</div>
                    <div class="text-white font-bold text-lg">${exchange.fee}%</div>
                </div>
                <div>
                    <div class="text-gray-400 text-sm mb-1">成立年份</div>
                    <div class="text-white font-bold text-lg">${exchange.founded}</div>
                </div>
            </div>
            
            <div class="mb-4">
                <div class="text-gray-400 text-sm mb-2">交易量对比</div>
                <div class="bg-gray-700 rounded-full h-2">
                    <div class="volume-bar rounded-full h-2" style="width: ${(exchange.volume24h / 30000000000) * 100}%"></div>
                </div>
            </div>
            
            <div class="flex flex-wrap gap-2 mb-4">
                ${exchange.features.map(feature => 
                    `<span class="bg-blue-600 text-white px-3 py-1 rounded-full text-sm">${feature}</span>`
                ).join('')}
            </div>
            
            <div class="flex space-x-3">
                <button class="flex-1 bg-yellow-600 text-white py-2 rounded-lg hover:bg-yellow-700 transition-colors font-medium">
                    访问网站
                </button>
                <button class="px-4 bg-gray-600 text-white py-2 rounded-lg hover:bg-gray-700 transition-colors">
                    详情
                </button>
            </div>
        `;
        
        container.appendChild(exchangeElement);
    });
}

function generatePriceHistory(basePrice, volatility = 0.05, days = 30) {
    const history = [];
    let currentPrice = basePrice;
    const now = new Date();
    
    for (let i = days; i >= 0; i--) {
        const date = new Date(now.getTime() - i * 24 * 60 * 60 * 1000);
        const change = (Math.random() - 0.5) * volatility;
        currentPrice = currentPrice * (1 + change);
        history.push({
            date: date.toISOString().split('T')[0],
            price: currentPrice
        });
    }
    return history;
}

// 初始化历史数据
Object.keys(cryptoData).forEach(symbol => {
    cryptoData[symbol].history = generatePriceHistory(cryptoData[symbol].price);
});

// DOM操作函数
function updatePriceDisplay(symbol) {
    const coin = cryptoData[symbol];
    if (!coin) return;

    const priceElement = document.getElementById('current-price');
    const changeElement = document.getElementById('price-change');
    const marketCapElement = document.getElementById('market-cap');
    const volumeElement = document.getElementById('volume-24h');

    if (priceElement) {
        priceElement.textContent = formatPrice(coin.price);
        priceElement.className = coin.change24h >= 0 ? 'text-green-400' : 'text-red-400';
    }

    if (changeElement) {
        const changeText = `${coin.change24h >= 0 ? '+' : ''}${coin.change24h.toFixed(2)}%`;
        changeElement.textContent = changeText;
        changeElement.className = coin.change24h >= 0 ? 'text-green-400' : 'text-red-400';
    }

    if (marketCapElement) {
        marketCapElement.textContent = formatMarketCap(coin.marketCap);
    }

    if (volumeElement) {
        volumeElement.textContent = formatVolume(coin.volume24h);
    }
}

function createPriceChart(symbol) {
    const chartElement = document.getElementById('price-chart');
    if (!chartElement) return;

    if (priceChart) {
        priceChart.dispose();
    }

    priceChart = echarts.init(chartElement);
    const coin = cryptoData[symbol];
    
    const option = {
        backgroundColor: 'transparent',
        grid: {
            left: '3%',
            right: '4%',
            bottom: '3%',
            containLabel: true
        },
        xAxis: {
            type: 'category',
            data: coin.history.map(h => h.date),
            axisLine: { lineStyle: { color: '#2d3748' } },
            axisLabel: { color: '#a0aec0' }
        },
        yAxis: {
            type: 'value',
            axisLine: { lineStyle: { color: '#2d3748' } },
            axisLabel: { 
                color: '#a0aec0',
                formatter: function(value) {
                    return '$' + value.toLocaleString();
                }
            },
            splitLine: { lineStyle: { color: '#2d3748', opacity: 0.3 } }
        },
        series: [{
            data: coin.history.map(h => h.price),
            type: 'line',
            smooth: true,
            lineStyle: {
                color: '#f7931a',
                width: 3
            },
            areaStyle: {
                color: {
                    type: 'linear',
                    x: 0, y: 0, x2: 0, y2: 1,
                    colorStops: [
                        { offset: 0, color: 'rgba(247, 147, 26, 0.3)' },
                        { offset: 1, color: 'rgba(247, 147, 26, 0.05)' }
                    ]
                }
            },
            symbol: 'none'
        }],
        tooltip: {
            trigger: 'axis',
            backgroundColor: '#1a1f2e',
            borderColor: '#f7931a',
            textStyle: { color: '#ffffff' },
            formatter: function(params) {
                const data = params[0];
                return `${data.axisValue}<br/>${coin.symbol}: $${data.value.toLocaleString()}`;
            }
        }
    };

    priceChart.setOption(option);
}

function createComparisonChart() {
    const chartElement = document.getElementById('comparison-chart');
    if (!chartElement) return;

    if (comparisonChart) {
        comparisonChart.dispose();
    }

    comparisonChart = echarts.init(chartElement);
    
    const series = comparisonCoins.map(symbol => {
        const coin = cryptoData[symbol];
        return {
            name: coin.symbol,
            type: 'line',
            data: coin.history.map(h => h.price),
            smooth: true,
            lineStyle: { width: 2 },
            symbol: 'none'
        };
    });

    const colors = ['#f7931a', '#00d4aa', '#627eea', '#ff6b6b'];
    
    const option = {
        backgroundColor: 'transparent',
        legend: {
            data: comparisonCoins.map(symbol => cryptoData[symbol].symbol),
            textStyle: { color: '#ffffff' },
            top: 10
        },
        grid: {
            left: '3%',
            right: '4%',
            bottom: '3%',
            top: '15%',
            containLabel: true
        },
        xAxis: {
            type: 'category',
            data: cryptoData[comparisonCoins[0]].history.map(h => h.date),
            axisLine: { lineStyle: { color: '#2d3748' } },
            axisLabel: { color: '#a0aec0' }
        },
        yAxis: {
            type: 'value',
            axisLine: { lineStyle: { color: '#2d3748' } },
            axisLabel: { 
                color: '#a0aec0',
                formatter: function(value) {
                    return '$' + value.toLocaleString();
                }
            },
            splitLine: { lineStyle: { color: '#2d3748', opacity: 0.3 } }
        },
        series: series.map((s, index) => ({
            ...s,
            lineStyle: { ...s.lineStyle, color: colors[index % colors.length] },
            itemStyle: { color: colors[index % colors.length] }
        })),
        tooltip: {
            trigger: 'axis',
            backgroundColor: '#1a1f2e',
            borderColor: '#f7931a',
            textStyle: { color: '#ffffff' }
        }
    };

    comparisonChart.setOption(option);
}

function updateCoinSelector() {
    const selector = document.getElementById('coin-selector');
    if (!selector) return;

    selector.innerHTML = '';
    
    Object.keys(cryptoData).forEach(symbol => {
        const coin = cryptoData[symbol];
        const option = document.createElement('option');
        option.value = symbol;
        option.textContent = `${coin.name} (${coin.symbol})`;
        option.selected = symbol === currentCoin;
        selector.appendChild(option);
    });
}

function updateComparisonSelectors() {
    const container = document.getElementById('comparison-selectors');
    if (!container) return;

    container.innerHTML = '';
    
    comparisonCoins.forEach((symbol, index) => {
        const select = document.createElement('select');
        select.className = 'bg-gray-800 text-white p-2 rounded border border-gray-600';
        select.dataset.index = index;
        
        Object.keys(cryptoData).forEach(coinSymbol => {
            const coin = cryptoData[coinSymbol];
            const option = document.createElement('option');
            option.value = coinSymbol;
            option.textContent = coin.symbol;
            option.selected = coinSymbol === symbol;
            select.appendChild(option);
        });
        
        select.addEventListener('change', function() {
            const newSymbol = this.value;
            const idx = parseInt(this.dataset.index);
            if (!comparisonCoins.includes(newSymbol)) {
                comparisonCoins[idx] = newSymbol;
                updateComparisonSelectors();
                createComparisonChart();
            }
        });
        
        container.appendChild(select);
    });
}

function updateTopCoinsList() {
    const container = document.getElementById('top-coins-list');
    if (!container) return;

    const sortedCoins = Object.values(cryptoData)
        .sort((a, b) => b.marketCap - a.marketCap)
        .slice(0, 10);

    container.innerHTML = '';
    
    sortedCoins.forEach((coin, index) => {
        const coinElement = document.createElement('div');
        coinElement.className = 'flex items-center justify-between p-3 bg-gray-800 rounded-lg hover:bg-gray-700 cursor-pointer transition-colors';
        coinElement.innerHTML = `
            <div class="flex items-center space-x-3">
                <span class="text-gray-400 font-medium">#${index + 1}</span>
                <div class="w-8 h-8 bg-gray-600 rounded-full flex items-center justify-center">
                    <span class="text-xs font-bold">${coin.symbol}</span>
                </div>
                <div>
                    <div class="text-white font-medium">${coin.name}</div>
                    <div class="text-gray-400 text-sm">${coin.symbol}</div>
                </div>
            </div>
            <div class="text-right">
                <div class="text-white font-medium">${formatPrice(coin.price)}</div>
                <div class="text-sm ${coin.change24h >= 0 ? 'text-green-400' : 'text-red-400'}">
                    ${coin.change24h >= 0 ? '+' : ''}${coin.change24h.toFixed(2)}%
                </div>
            </div>
        `;
        
        coinElement.addEventListener('click', () => {
            currentCoin = coin.symbol;
            updateCoinSelector();
            updatePriceDisplay(currentCoin);
            createPriceChart(currentCoin);
        });
        
        container.appendChild(coinElement);
    });
}

function updateExchangeList() {
    const container = document.getElementById('exchange-list');
    if (!container) return;

    container.innerHTML = '';
    
    exchangeData.forEach(exchange => {
        const exchangeElement = document.createElement('div');
        exchangeElement.className = 'bg-gray-800 rounded-lg p-6 hover:bg-gray-700 transition-colors';
        exchangeElement.innerHTML = `
            <div class="flex items-center justify-between mb-4">
                <h3 class="text-xl font-bold text-white">${exchange.name}</h3>
                <div class="text-right">
                    <div class="text-green-400 font-medium">${formatVolume(exchange.volume24h)}</div>
                    <div class="text-gray-400 text-sm">24h Volume</div>
                </div>
            </div>
            <div class="grid grid-cols-2 gap-4 mb-4">
                <div>
                    <div class="text-gray-400 text-sm">Trading Pairs</div>
                    <div class="text-white font-medium">${exchange.pairs.toLocaleString()}</div>
                </div>
                <div>
                    <div class="text-gray-400 text-sm">Trading Fee</div>
                    <div class="text-white font-medium">${exchange.fee}%</div>
                </div>
                <div>
                    <div class="text-gray-400 text-sm">Founded</div>
                    <div class="text-white font-medium">${exchange.founded}</div>
                </div>
                <div>
                    <div class="text-gray-400 text-sm">Security Score</div>
                    <div class="text-white font-medium">${exchange.security}/10</div>
                </div>
            </div>
            <div class="flex flex-wrap gap-2">
                ${exchange.features.map(feature => 
                    `<span class="bg-blue-600 text-white px-2 py-1 rounded text-xs">${feature}</span>`
                ).join('')}
            </div>
        `;
        
        container.appendChild(exchangeElement);
    });
}

// 事件监听器
function initializeEventListeners() {
    const coinSelector = document.getElementById('coin-selector');
    if (coinSelector) {
        coinSelector.addEventListener('change', function() {
            currentCoin = this.value;
            updatePriceDisplay(currentCoin);
            createPriceChart(currentCoin);
        });
    }

    // 时间范围选择器
    const timeRangeButtons = document.querySelectorAll('.time-range-btn');
    timeRangeButtons.forEach(btn => {
        btn.addEventListener('click', function() {
            timeRangeButtons.forEach(b => b.classList.remove('active'));
            this.classList.add('active');
            // 这里可以添加更新图表时间范围的逻辑
        });
    });

    // 响应式图表调整
    window.addEventListener('resize', function() {
        if (priceChart) priceChart.resize();
        if (comparisonChart) comparisonChart.resize();
    });
}

// 模拟实时价格更新
function simulateRealTimeUpdates() {
    setInterval(() => {
        Object.keys(cryptoData).forEach(symbol => {
            const coin = cryptoData[symbol];
            const volatility = 0.002; // 0.2% volatility
            const change = (Math.random() - 0.5) * volatility;
            coin.price = coin.price * (1 + change);
            
            // 更新24小时涨跌幅
            const change24hChange = (Math.random() - 0.5) * 0.1;
            coin.change24h = coin.change24h + change24hChange;
            
            // 如果当前显示的是这个币种，更新显示
            if (symbol === currentCoin) {
                updatePriceDisplay(symbol);
            }
        });
        
        // 每10秒更新一次对比图表
        if (Math.random() < 0.1) {
            createComparisonChart();
        }
    }, 2000);
}

// 页面初始化函数
function initializePage() {
    // 初始化各个组件
    updateCoinSelector();
    updatePriceDisplay(currentCoin);
    updateTopCoinsList();
    updateExchangeList();
    
    // 延迟初始化图表，确保DOM元素已渲染
    setTimeout(() => {
        createPriceChart(currentCoin);
        updateComparisonSelectors();
        createComparisonChart();
    }, 100);
    
    // 初始化事件监听器
    initializeEventListeners();
    
    // 启动实时更新模拟
    simulateRealTimeUpdates();
    
    // 初始化动画效果
    initializeAnimations();
}

// 动画初始化
function initializeAnimations() {
    // 页面加载动画
    anime({
        targets: '.fade-in',
        opacity: [0, 1],
        translateY: [20, 0],
        duration: 800,
        delay: anime.stagger(100),
        easing: 'easeOutQuart'
    });
    
    // 价格数字滚动动画
    anime({
        targets: '.price-number',
        innerHTML: function(el) {
            return [0, parseFloat(el.textContent.replace(/[^0-9.-]+/g, ''))];
        },
        duration: 2000,
        round: 100,
        easing: 'easeOutExpo'
    });
}

// 页面加载完成后初始化
document.addEventListener('DOMContentLoaded', initializePage);