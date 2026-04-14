fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Realistic Scripts'
name 'rs-realistic-parking'
description 'Players can park their vehicles on streets or in parking lots for a natural & realistic real world feel.'
version 'v1.0.0'
repository 'https://github.com/RealisticScripts/rs-realistic-parking'
license 'MIT'

dependencies {
    'ox_lib',
    'oxmysql',
    'qb-core',
    'qb-target'
}

files {
    'locales/*.lua'
}

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/lang.lua'
}

server_script {
    '@oxmysql/lib/MySQL.lua',
    'server.lua'
}

client_script {
    'client.lua'
}
