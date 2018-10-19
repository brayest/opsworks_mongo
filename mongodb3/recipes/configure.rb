package 'awscli'
include_recipe "mongodb3::mongo_gem"

require 'json'
require 'mongo'
require 'bson'

# Obtaning mongo instnaces
this_instance = search("aws_opsworks_instance", "self:true").first
layer_id = this_instance["layer_ids"][0]
client = Mongo::Client.new([ '127.0.0.1' ], :database => "admin" ,:connect => "direct", :server_selection_timeout => 5)


rs_members = []
rs_member_ips = []
i = 0
search("aws_opsworks_instance", "layer_ids:#{layer_id}").each do |instance|
  i += 1
  rs_members << {"_id" => i, "host" => "#{instance['hostname']}"}
  rs_member_ips << {"_id" => i, "host" => "#{instance['ipaddress']}"}
end

# TODO Get the node status, and exist until they all are in online state
ruby_block 'Configuring_replica_set' do
  block do
    Chef::Log.info "Checking configuration"
    if "#{node['is_initiated']}" != ""
      master_node_command="aws opsworks --region us-east-1 describe-instances --layer-id #{layer_id} --query 'Instances[0].Hostname'"
      master_node=`#{master_node_command}`.delete!("\n").delete!("\"")
      Chef::Log.info "Checking hostname " + master_node
      if master_node == this_instance["hostname"]
        Chef::Log.info "Initializing replica set"
        cmd = {}
        cmd['replSetInitiate'] = {
            "_id" => "#{node['mongodb3']['config']['mongod']['replication']['replSetName']}",
            "members" => rs_members
        }
        client.database.command(cmd)
        system("aws opsworks --region us-east-1 update-layer --layer-id #{layer_id} --custom-json " + '"{\"is_initiated\":\"yes\"}"' )
      end
    end
  end
end

# ruby_block 'Adding_slaves' do
#   block do
#     mongo_nodes.each do |host|
#       Chef::Log.info "Adding nodes"
#       if host != this_instance["hostname"]
#         system("echo \"rs.add('#{host}:27017')\" | mongo")
#       end
#     end
#   end
# end
#
# ruby_block 'Removing unhealthy nodes' do
#   block do
#     sleep(60)
#     command_status_of_nodes="echo \"rs.status().members\" | mongo --quiet | grep health\\\" | awk ' {print $3} '"
#     status_of_nodes=`#{command_status_of_nodes}`.delete!("\n").delete!(",")
#     nodes=status_of_nodes.split("")
#     for index_node in 0..nodes.size-1 do
#       if nodes[index_node] != "1"
#         Chef::Log.info "node index unhealthy " + index_node.to_s
#         command="echo \"rs.status().members[#{index_node}]['name']\" | mongo --quiet"
#         unhealthy_node=`#{command}`.delete!("\n")
#         Chef::Log.info "deleting unhealthy node " + unhealthy_node
#         system("echo 'rs.remove(\"#{unhealthy_node}\")' | mongo")
#       else
#         Chef::Log.info "node index healthy "  + index_node.to_s
#         command="echo \"rs.status().members[#{index_node}]['name']\" | mongo --quiet"
#         healthy_node=`#{command}`.delete!("\n")
#         Chef::Log.info "healthy node " + healthy_node
#       end
#     end
#
#   end
# end
