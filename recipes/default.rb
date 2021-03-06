# frozen_string_literal: true

# Cookbook:: chef_server_wrapper
# Recipe:: default
#
# Copyright:: 2019, The Authors, All Rights Reserved.

# suse hostname fix - sles 12 sp5
if platform_family?('suse') && File.readlines('/etc/hosts').grep(/`hostname`/).empty?
  open('/etc/hosts', 'a') do |f|
    f << "127.0.0.1 #{`hostname`}"
  end
end

hostname = if node['chef_server_wrapper']['fqdn'] != ''
             node['chef_server_wrapper']['fqdn']
           elsif node['cloud'] && node['chef_server_wrapper']['cloud_public_address']
             node['cloud']['public_ipv4_addrs'].first
           else
             node['ipaddress']
           end

config = if node['chef_server_wrapper']['config_block'] != {}
           node['chef_server_wrapper']['config_block'][hostname]
         else
           ''
         end

config += <<~CONFIG

  #{node['chef_server_wrapper']['config']}
CONFIG

if node['chef_server_wrapper']['cert'] != '' &&
   node['chef_server_wrapper']['cert_key'] != ''

  cert_dir = node['chef_server_wrapper']['cert_directory']
  cert_path = "#{cert_dir}/#{hostname}.crt"
  cert_key_path = "#{cert_dir}/#{hostname}.key"

  directory cert_dir do
    mode '0700'
    owner 'root'
    group 'root'
  end

  file cert_path do
    content node['chef_server_wrapper']['cert']
    mode '0644'
    owner 'root'
    group 'root'
  end

  file cert_key_path do
    content node['chef_server_wrapper']['cert_key']
    mode '0600'
    owner 'root'
    group 'root'
  end

  # rabbitmq managmenent disabled when using non chef
  # generated certs see: https://github.com/chef/chef-server/issues/1418
  config += <<~CONFIG
    nginx['ssl_certificate']  = "#{cert_path}"
    nginx['ssl_certificate_key']  = "#{cert_key_path}"
    rabbitmq['management_enabled'] = false
  CONFIG
end

config += if node['chef_server_wrapper']['supermarket_url'] != ''
            <<~CONFIG
              oc_id['applications'] ||= {}
              oc_id['applications']['supermarket'] = {
                'redirect_uri' => 'https://#{node['chef_server_wrapper']['supermarket_url']}/auth/chef_oauth2/callback'
              }
            CONFIG
          else
            <<~CONFIG
            CONFIG
          end

config += if node['chef_server_wrapper']['data_collector_url'] != ''
            <<~CONFIG
              data_collector['root_url'] = '#{node['chef_server_wrapper']['data_collector_url']}/data-collector/v0/'
              data_collector['proxy'] = true
              profiles['root_url'] = '#{node['chef_server_wrapper']['data_collector_url']}'
            CONFIG
          else
            <<~CONFIG
            CONFIG

          end

config += if node['chef_server_wrapper']['data_collector_token'] != ''
            <<~CONFIG
              data_collector['token'] =  '#{node['chef_server_wrapper']['data_collector_token']}'

            CONFIG
          else
            <<~CONFIG
            CONFIG
          end

directory '/etc/opscode' do
  action :create
  only_if { node['chef_server_wrapper']['frontend_secrets'] != '' }
end

remote_file '/bin/jq' do
  source node['chef_server_wrapper']['jq_url']
  mode '0755'
end

config += if hostname != node['cloud']['public_ipv4_addrs'].first && hostname != node['ipaddress']
            <<~CONFIG
              api_fqdn = '#{hostname}'

            CONFIG
          else
            <<~CONFIG
            CONFIG
          end

# The following file and directory resources are used
# when configuring additional chef server frontends to an
# exisiting cluster with a frontend.
# The attribute frontend_secrets would be taken from the existing frontend node

# fix for passing data from terraform
node.override['chef_server_wrapper']['frontend_secrets'] = {} if node['chef_server_wrapper']['frontend_secrets'].nil?

directory '/var/opt/opscode/upgrades/' do
  action :create
  recursive true
  not_if { node['chef_server_wrapper']['frontend_secrets'].empty? }
end

template '/etc/opscode/private-chef-secrets.json' do
  source 'private-chef-secrets.json.erb'
  variables(
    veil_hasher_secret: node['chef_server_wrapper']['frontend_secrets']['veil_hasher_secret'],
    veil_hasher_salt: node['chef_server_wrapper']['frontend_secrets']['veil_hasher_salt'],
    veil_cipher_key: node['chef_server_wrapper']['frontend_secrets']['veil_cipher_key'],
    veil_cipher_iv: node['chef_server_wrapper']['frontend_secrets']['veil_cipher_iv'],
    veil_credentials: node['chef_server_wrapper']['frontend_secrets']['veil_credentials']
  )
  not_if { node['chef_server_wrapper']['frontend_secrets'].empty? }
end

template '/var/opt/opscode/upgrades/migration-level' do
  source 'migration-level.erb'
  variables(
    major: node['chef_server_wrapper']['frontend_secrets']['migration_major'],
    minor: node['chef_server_wrapper']['frontend_secrets']['migration_minor']
  )
  not_if { node['chef_server_wrapper']['frontend_secrets'].empty? }
end

file '/var/opt/opscode/bootstrapped' do
  action :create_if_missing
  not_if { node['chef_server_wrapper']['frontend_secrets'].empty? }
end

chef_ingredient 'chef-server' do
  channel node['chef_server_wrapper']['channel'].to_sym
  version node['chef_server_wrapper']['version']
  config config
  ctl_command node['chef_server_wrapper']['ctl_command']
  action %i[install reconfigure]
end

execute 'chef-server-reconfigure-first-boot' do
  command 'chef-server-ctl reconfigure'
  not_if { File.exist?('/etc/opscode/pivotal.rb') }
end

# we offer suse linux chef server packages but no
# addon packages are build for suse
if node['platform_family'] == 'suse' && node['chef_server_wrapper']['addons'] != {}
  platform = 'el'
  platform_version = '7'
end

node['chef_server_wrapper']['addons'].each do |addon, options|
  chef_ingredient addon do
    action :upgrade
    channel options['channel'].to_sym || :stable
    version options['version'] || :latest
    config options['config'] || ''
    accept_license node['chef_server_wrapper']['accept_license'].to_s == 'true'
    platform platform if platform
    platform_version platform_version if platform_version
  end

  ingredient_config addon do
    notifies :reconfigure, "chef_ingredient[#{addon}]", :immediately
  end
end

if node['chef_server_wrapper']['chef_orgs'] != {} &&
   node['chef_server_wrapper']['chef_users'] != {}

  node['chef_server_wrapper']['chef_users'].each do |name, params|
    chef_user name do
      first_name params['first_name']
      last_name params['last_name']
      email params['email']
      password params['password']
      serveradmin params['serveradmin']
    end
  end

  node['chef_server_wrapper']['chef_orgs'].each do |name, params|
    chef_org name do
      org_full_name params['org_full_name']
      admins params['admins']
    end
  end
end

template node['chef_server_wrapper']['details_script_path'] do
  extend ChefServerWrapper::ServerHelpers
  source 'chef_server_details.sh.erb'
  variables(
    user: node['chef_server_wrapper']['starter_pack_user'],
    org: node['chef_server_wrapper']['starter_pack_org'],
    client_pem: lazy { read_pem('client', node['chef_server_wrapper']['starter_pack_user']).inspect },
    validation_pem: lazy { read_pem('org', node['chef_server_wrapper']['starter_pack_org']).inspect },
    fqdn: hostname
  )
end

cookbook_file node['chef_server_wrapper']['frontend_script_path'] do
  source 'frontend_secrets.sh'
end
