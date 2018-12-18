include_recipe "mongodb3::mongo_gem"

require 'json'
require 'mongo'
require 'bson'
require 'aws-sdk-opsworks'
require 'aws-sdk-route53'
require 'aws-sdk-ssm'

# Obtaning mongo instnaces
this_instance = search("aws_opsworks_instance", "self:true").first
layer_id = this_instance["layer_ids"][0]

ssm = Aws::SSM::Client.new(:region => "#{node['Region']}")
userParam = ssm.get_parameter({
    name: "#{node['DBUser']}",
    with_decryption: false
})
user = userParam[:parameter][:value]
passwordParam = ssm.get_parameter({
    name: "#{node['DBPassword']}",
    with_decryption: false
})
password = passwordParam[:parameter][:value]

begin
  mongo = Mongo::Client.new([ "127.0.0.1:#{node['mongodb3']['config']['mongod']['net']['port']}" ], :database => "admin", :user => user, :password => password, :connect => "direct", :server_selection_timeout => 5)
  mongo.database_names
rescue
  mongo = Mongo::Client.new([ "127.0.0.1:#{node['mongodb3']['config']['mongod']['net']['port']}" ], :database => "admin", :connect => "direct", :server_selection_timeout => 5)
end

opsworks = Aws::OpsWorks::Client.new(:region => "us-east-1")
dns = Aws::Route53::Client.new(:region => "#{node['Region']}")

rs_members = []
rs_member_ips = []
i = 0
configured = true

ruby_block 'Configuring_replica_set' do
  block do
    Chef::Log.info "Checking configuration"
    config = {}
    config['replSetGetConfig'] = 1

    host_names = []
    host_ips = []

    master_node_command = opsworks.describe_instances({
      layer_id: layer_id,
    })

    init_hosts = []
    master_node_command.instances.each do |host|
      begin
        begin
          check = Mongo::Client.new([ "127.0.0.1:#{node['mongodb3']['config']['mongod']['net']['port']}" ], :database => "admin", :user => user, :password => password, :connect => "direct", :server_selection_timeout => 5)
          check.database_names
        rescue
          check = Mongo::Client.new([ "127.0.0.1:#{node['mongodb3']['config']['mongod']['net']['port']}" ], :database => "admin", :connect => "direct", :server_selection_timeout => 5)
        end
        check.database.command(config)
        Chef::Log.info "Configuration found"
        init_hosts.push(true)
      rescue Mongo::Auth::Unauthorized, Mongo::Error => e
        info_string  = "Error #{e.class}: #{e.message}"
        Chef::Log.info "No configuration found: " + info_string
        init_hosts.push(false)
        begin
          check.database_names
          i += 1
          rs_members << {"_id" => i, "host" => "#{node['HostID']}#{i-1}.#{node['Domain']}:#{node['mongodb3']['config']['mongod']['net']['port']}"}
          host_names.push("#{node['HostID']}#{i-1}.#{node['Domain']}")
          host_ips.push(host.private_ip)
        rescue Mongo::Auth::Unauthorized, Mongo::Error => e
          info_string  = "Error #{e.class}: #{e.message}"
          Chef::Log.info "Unable to connecto to host, member not added: " + info_string
        end
      end
    end

    Chef::Log.info "Configuration found: " + init_hosts.join(", ")

    unless init_hosts.include?(true)
      configured = false
    end

    unless configured
      master_node= master_node_command.instances[0].hostname
      Chef::Log.info "Checking hostname " + master_node
      if master_node == this_instance["hostname"]
        Chef::Log.info "Initializing replica set"
        cmd = {}
        cmd['replSetInitiate'] = {
            "_id" => "#{node['mongodb3']['config']['mongod']['replication']['replSetName']}",
            "members" => rs_members
        }

        for j in 0..host_names.size-1 do
          resp = dns.change_resource_record_sets({
            change_batch: {
              changes: [
                {
                  action: "CREATE",
                  resource_record_set: {
                    name: "#{node['HostID']}#{j}.#{node['Domain']}",
                    resource_records: [
                      {
                        value: "#{host_ips[j]}",
                      },
                    ],
                    ttl: 60,
                    type: "A",
                  },
                },
              ],
              comment: "Mongo service discovery for #{node['HostID']}",
            },
            hosted_zone_id: "#{node['HostedZoneId']}",
          })
        end

        until configured
          begin
            mongo.database.command(cmd)
            configured = true
          rescue Mongo::Auth::Unauthorized, Mongo::Error => e
            info_string  = "Error #{e.class}: #{e.message}"
            Chef::Log.info "Initialization failed: " + info_string
            sleep(30)
          end
        end

      end
    end
  end
end

ruby_block 'Adding and removing members' do
  block do
    master_node_command = opsworks.describe_instances({
      layer_id: layer_id,
    })
    Chef::Log.info "Cluster configured checking hosts: " + configured.to_s
    if configured
      cmd = {}
      cmd['replSetGetStatus'] = 1
      status = mongo.database.command(cmd)
      config = {}
      config['replSetGetConfig'] = 1
      config = mongo.database.command(config)
      version = config.documents[0]["config"]["version"].to_i
      Chef::Log.info "Configuration version: " + version.to_s
      state = status.documents[0]

      if state["myState"].to_i == 1
        sleep(30)
        Chef::Log.info "Master member, state: " + state["myState"].to_s
        Chef::Log.info "Cluster size: " + state["members"].size.to_s

        rs_new_members = []
        members = []
        host_names = []
        host_ips = []
        health = true
        for member in state["members"] do
          members.push("#{member["name"]}")
          if member["state"].to_i != 1 && member["health"].to_i == 0
            Chef::Log.info "Member unhealthy, deleting: " + member["name"].to_s
            health = false
          else
            begin
              begin
                check = Mongo::Client.new([ "#{member["name"]}:#{node['mongodb3']['config']['mongod']['net']['port']}" ], :database => "admin", :user => user, :password => password, :connect => "direct", :server_selection_timeout => 5)
                check.database_names
              rescue
                check = Mongo::Client.new([ "#{member["name"]}:#{node['mongodb3']['config']['mongod']['net']['port']}" ], :database => "admin", :connect => "direct", :server_selection_timeout => 5)
                check.database_names
              end
              old_member = member["name"].split(":")[0].downcase
              rs_new_members << {"_id" => member["_id"], "host" => "#{old_member}:#{node['mongodb3']['config']['mongod']['net']['port']}"}
              i = member["_id"]

              host_names.push("#{old_member}")

              dnsrsets = dns.list_resource_record_sets({
                hosted_zone_id: "#{node['HostedZoneId']}",
              })

              dnsrsets.resource_record_sets.each do |old_record|
                  if "#{old_record.name}" == "#{old_member}."
                    hst_private_ip = old_record.resource_records[0].value
                    host_ips.push(hst_private_ip)
                  end
              end

              Chef::Log.info "Member healthy, skipping: " + member["name"].to_s
            rescue Mongo::Auth::Unauthorized, Mongo::Error => e
              available = false
              health = false
              info_string  = "Error #{e.class}: #{e.message}"
              Chef::Log.info "Member Unavailable, removing: " + info_string
            end
          end
        end

        Chef::Log.info "Members healthy #{host_names.join(", ")}"

        Chef::Log.info "Checking for new members"
        master_node_command.instances.each do |host|
          host_ip = host.private_ip
          unless host_ips.include?(host_ip)
            i += 1
            available = true
            Chef::Log.info "New member found, checking availability: " + host.hostname
            
            begin
              begin
                check = Mongo::Client.new([ "#{host_ip}:#{node['mongodb3']['config']['mongod']['net']['port']}" ], :database => "admin", :user => user, :password => password, :connect => "direct", :server_selection_timeout => 5)
              rescue
                check = Mongo::Client.new([ "#{host_ip}:#{node['mongodb3']['config']['mongod']['net']['port']}" ], :database => "admin", :connect => "direct", :server_selection_timeout => 5)
              end
            rescue Mongo::Auth::Unauthorized, Mongo::Error => e
              available = false
              info_string  = "Error #{e.class}: #{e.message}"
              Chef::Log.info "Member Unavailable: " + info_string
            end

            if available
              digits = []
              host_names.each do |number|
                letters = number.split(".")[0].split("")
                digit = letters[letters.length-1]
                digits.push(digit)
                Chef::Log.info " #{number} Nnumber: " + digit.to_s
              end

              number = digits.size
              Chef::Log.info " Digits " + digits.to_s
              for x in 0..number do
                Chef::Log.info " Number " + x.to_s
                unless digits.include?(x.to_s)
                  number = x
                end
              end

              Chef::Log.info " Number " + x.to_s

              rs_new_members << {"_id" => i, "host" => "#{node['HostID']}#{number}.#{node['Domain']}:#{node['mongodb3']['config']['mongod']['net']['port']}"}
              host_names.push("#{node['HostID']}#{number}.#{node['Domain']}")
              host_ips.push(host.private_ip)
              Chef::Log.info "New member added: #{node['HostID']}#{number}.#{node['Domain']}"
              health = false
            end
          end
        end

        if health
          Chef::Log.info "Cluster healthy, no reconfiguration needed"
        else
          Chef::Log.info "Cluster unhealthy, reconfiguration needed"
          new_version = version + 1
          Chef::Log.info "New configuration version: " + new_version.to_s
          cmd = {}
          cmd['replSetReconfig'] = {
            "version" => new_version,
            "_id" => "#{node['mongodb3']['config']['mongod']['replication']['replSetName']}",
            "members" => rs_new_members
          }
          begin

            dnsrsets = dns.list_resource_record_sets({
              hosted_zone_id: "#{node['HostedZoneId']}",
            })

            dnsrsets.resource_record_sets.each do |old_record|
              unless "#{old_record.name}" == "#{node['Domain']}."
                Chef::Log.info "Removing RecordSet: " + old_record.name.to_s
                resp = dns.change_resource_record_sets({
                  change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "#{old_record.name}",
                          resource_records: [
                            {
                              value: "#{old_record.resource_records[0].value}",
                            },
                          ],
                          ttl: 60,
                          type: "A",
                        },
                      },
                    ],
                    comment: "Mongo service discovery for #{node['HostID']}",
                  },
                  hosted_zone_id: "#{node['HostedZoneId']}",
                })
              end
            end

            for j in 0..host_names.size-1 do
              resp = dns.change_resource_record_sets({
                change_batch: {
                  changes: [
                    {
                      action: "CREATE",
                      resource_record_set: {
                        name: "#{host_names[j]}",
                        resource_records: [
                          {
                            value: "#{host_ips[j]}",
                          },
                        ],
                        ttl: 60,
                        type: "A",
                      },
                    },
                  ],
                  comment: "Mongo service discovery for #{node['HostID']}",
                },
                hosted_zone_id: "#{node['HostedZoneId']}",
              })
            end

            mongo.database.command(cmd)

          rescue Mongo::Auth::Unauthorized, Mongo::Error => e
            info_string  = "Error #{e.class}: #{e.message}"
            Chef::Log.info "Re-Initialization failed: " + info_string
          end
        end

      end
    end
  end
end

package 'awscli'

cron 'backup1' do
  action :create
  minute '0'
  hour '0'
  user 'root'
  home '/home/ubuntu'
  command "/home/ubuntu/backup_cronjob.sh #{node['BackUpBucket']} #{node['HostID']} A"
end

cron 'backup2' do
  action :create
  minute '0'
  hour '12'
  user 'root'
  home '/home/ubuntu'
  command "/home/ubuntu/backup_cronjob.sh #{node['BackUpBucket']} #{node['HostID']} B"
end

cookbook_file '/home/ubuntu/backup_cronjob.sh' do
  source 'backup_cronjob.sh'
  owner 'root'
  group 'root'
  mode '0777'
  action :create
end

# Key file contents
node.default['mongodb3']['config']['key_file_content'] = 'n/XmT8wIOmKSwVqV5UPUcEf23ugCoL6uRVV0C2u9Ilg0+pb2SfS5vWYvXY7UhL6J
/+orKuREnH9gHSmsgEIPSEMKopGTwsoXpPXW1jWH9TzFt4z8PL81z+/Qz+GuZOWN
+KMWltIua0EbfLEUw4sZb3xNT33EHjmbbDJWmVO2ngTr2zCb2Xubc0DvoTs2rTMe
hd/PkkqumLTJINRa4JP7i12cyldhbKWRk9ROVmVoyoyMhrXR38rwvMiD+4SJamtM
YDB3dktD22J2g/QMwrJtdM1GI3o2PwYeKA1v16OY/oqI7bJ77wdin6MKpYUTyenS
kDwU8pJwSbgMJ1i58EcokC1dyom1Lq9eIrjREpAovV837tZxylTEiAZAxbR7yHfD
6+uN+aN8BftMZK7nCe7hvJjlX7mt0P9fovJ5rrl22eR88O93yPV4vNdkQojTXJd+
M9mZNUOeYOWCa3E1XUN6USzI+XHZeVDfjxPT98GVdR+KwpTNUPLRp9lI020rAzRO
LX4Wi5/0rW5SETUqFRX+iIf7zdx/+7nuMI7FZsBGErdc6Oc1bvNlWw8xpVOtBTT8
0+DBG+uYX8isby7OXRDuXmNEDUJWBWmafsoX7cQ+687M1TryP9BOAcLZEkBmgIRC
D3u2uaXIqlkB8k/01dYS2TTUO1xbtbNmu3JaDJ5EtyPwUGTXD2mKsTYgzxRuQI5b
Y5PBH/n4ZL+CCmf0AVkZARGbm4yQvtT3cmIIyl01Fgm+6IcCTU6RwTdWkO+lypaq
zRwAeOaVtNMdON5nPF2h42yE6dkUBhxz3dXTcaC/0HjrYd2HKc0NDicOYTj744rK
6TrsywfMTJO9ZIQY6aKg8UXwYShqSEjWFMfwYLQi+S+efvvCqMnYWWNAGEF/xQBX
V12wd9ACwNez3e3w9LWxe2/gR8QBO/7zL5P4u7wTiu3OMH7Nyo008JoBRbWARu7t
pK/oM7oIKC7tb4Redd7EYIdLdFZIuMuqN/sYQxF31EDoI+I8'

# security Options : http://docs.mongodb.org/manual/reference/configuration-options/#security-options
node.default['mongodb3']['config']['mongod']['security']['keyFile'] = '/var/lib/keyfile'
node.default['mongodb3']['config']['mongod']['security']['clusterAuthMode'] = 'keyFile'

# Update the mongodb config file
template node['mongodb3']['mongod']['config_file'] do
  source 'mongodb.conf.erb'
  mode 0644
  variables(
      :config => node['mongodb3']['config']['mongod']
  )
  helpers Mongodb3Helper
end

unless node['mongodb3']['config']['key_file_content'].to_s.empty?
  # Create the key file if it is not exist
  key_file = node['mongodb3']['config']['mongod']['security']['keyFile']

  # Create the directory for key file
  directory File.dirname(key_file).to_s do
    action :create
    owner node['mongodb3']['user']
    group node['mongodb3']['group']
    recursive true
  end

  file key_file do
    content node['mongodb3']['config']['key_file_content']
    mode '0600'
    owner node['mongodb3']['user']
    group node['mongodb3']['group']
  end
end

# Restart the mongod service
service 'mongod' do
  case node['platform']
    when 'ubuntu'
      if node['platform_version'].to_f >= 15.04
        provider Chef::Provider::Service::Systemd
      elsif node['platform_version'].to_f >= 14.04
        provider Chef::Provider::Service::Upstart
      end
  end
  supports :start => true, :stop => true, :restart => true, :status => true
  action :enable
  subscribes :restart, "template[#{node['mongodb3']['mongod']['config_file']}]", :delayed
  subscribes :restart, "template[#{node['mongodb3']['config']['mongod']['security']['keyFile']}", :delayed
end