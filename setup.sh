#!/bin/bash

# Laravel + Next.js Stack Setup

set -e

cd "$(dirname "$0")"

# Get project name from parent folder
PROJECT_NAME=$(basename "$(dirname "$(pwd)")")

echo "Stack: Laravel + Next.js"
echo "Project: $PROJECT_NAME"
echo ""

# Step 1: Install dependencies
echo "Step 1: Install dependencies"
npm install
echo "✓ npm dependencies"

# Step 2: Create Laravel backend
echo "Step 2: Create backend"
if [ ! -d "backend" ]; then
    laravel new backend --no-interaction
    cd backend
    
    # Install API with Sanctum
    php artisan install:api --no-interaction
    
    # Install SSO Client package (from local)
    echo "Installing SSO Client (local)..."
    composer config repositories.omnify-client-laravel-sso path ../../packages/omnify-client-laravel-sso
    composer config --no-plugins allow-plugins.omnifyjp/omnify-client-laravel-sso true
    composer require omnifyjp/omnify-client-laravel-sso:@dev lcobucci/jwt --no-interaction
    
    # Remove frontend stuff
    rm -rf resources/js resources/css public/build
    rm -f vite.config.js package.json package-lock.json postcss.config.js tailwind.config.js
    rm -rf node_modules
    
    # Configure CORS
    cat > config/cors.php << EOF
<?php

return [
    'paths' => ['api/*', 'sanctum/csrf-cookie', 'sso/*'],
    'allowed_methods' => ['*'],
    'allowed_origins' => [],
    'allowed_origins_patterns' => [
        '#^https?://[a-z0-9-]+\\.test\$#i',
        '#^https?://[a-z0-9-]+\\.[a-z0-9-]+\\.test\$#i',
        '#^https?://localhost(:\d+)?\$#',
    ],
    'allowed_headers' => ['*'],
    'exposed_headers' => [],
    'max_age' => 0,
    'supports_credentials' => true,
];
EOF
    echo "✓ CORS configured"
    
    # Configure middleware (CSRF exclusion + statefulApi)
    cat > bootstrap/app.php << 'EOF'
<?php

use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        api: __DIR__.'/../routes/api.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
    )
    ->withMiddleware(function (Middleware $middleware): void {
        $middleware->validateCsrfTokens(except: [
            'api/sso/callback',
            'api/sso/*',
        ]);
        $middleware->statefulApi();
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        //
    })->create();
EOF
    echo "✓ Middleware configured"
    
    # Configure User model with SSO trait
    cat > app/Models/User.php << 'EOF'
<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;
use Omnify\SsoClient\Models\Traits\HasConsoleSso;

class User extends Authenticatable
{
    use HasFactory, Notifiable, HasConsoleSso;

    protected $fillable = [
        'name',
        'email',
        'password',
        'console_user_id',
        'console_access_token',
        'console_refresh_token',
        'console_token_expires_at',
    ];

    protected $hidden = [
        'password',
        'remember_token',
        'console_access_token',
        'console_refresh_token',
    ];

    protected function casts(): array
    {
        return [
            'email_verified_at' => 'datetime',
            'password' => 'hashed',
            'console_token_expires_at' => 'datetime',
        ];
    }
}
EOF
    echo "✓ User model configured"
else
    cd backend
fi

# Step 3: Setup backend environment
echo ""
echo "Step 3: Setup environment"
cat > .env << EOF
APP_NAME=Service
APP_KEY=
APP_ENV=local
APP_DEBUG=true
APP_URL=https://api.$PROJECT_NAME.test
FRONTEND_URL=https://$PROJECT_NAME.test

DB_CONNECTION=sqlite

SESSION_DRIVER=cookie
SESSION_DOMAIN=.$PROJECT_NAME.test
SESSION_SAME_SITE=none
SESSION_SECURE_COOKIE=true

SANCTUM_STATEFUL_DOMAINS=$PROJECT_NAME.test,api.$PROJECT_NAME.test

# SSO Configuration
SSO_CONSOLE_URL=https://auth-$PROJECT_NAME.test
SSO_SERVICE_SLUG=service
SSO_SERVICE_SECRET=local_dev_secret
EOF

php artisan key:generate --force

# Publish SSO config
php artisan vendor:publish --tag=sso-client-config --force 2>/dev/null || true
echo "✓ Environment configured"

# Step 3: Link backend to Herd
herd link api.$PROJECT_NAME
herd secure api.$PROJECT_NAME
echo "✓ https://api.$PROJECT_NAME.test"

# Step 4: Create Next.js frontend
echo ""
echo "Step 3: Create frontend"
cd ..
if [ ! -d "frontend" ]; then
    npx --yes create-next-app@latest frontend \
        --typescript \
        --tailwind \
        --eslint \
        --app \
        --src-dir \
        --import-alias "@/*" \
        --turbopack \
        --use-pnpm \
        --yes
    
    # Create .env.local
    cat > frontend/.env.local << EOF
NEXT_PUBLIC_API_URL=https://api.$PROJECT_NAME.test
NEXT_PUBLIC_SSO_URL=https://auth-$PROJECT_NAME.test
EOF
    
    # Install local React packages
    cd frontend
    pnpm add ../../packages/omnify-client-react ../../packages/omnify-client-react-sso
    cd ..
fi
echo "✓ frontend"

# Step 5: Proxy frontend to port 3000
herd proxy $PROJECT_NAME http://localhost:3000 --secure
echo "✓ https://$PROJECT_NAME.test → localhost:3000"

echo ""
echo "Done!"
echo "  API:      https://api.$PROJECT_NAME.test"
echo "  Frontend: https://$PROJECT_NAME.test (run: cd frontend && pnpm dev)"
