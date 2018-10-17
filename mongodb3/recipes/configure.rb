require 'json'
package 'awscli'
# Configure replicas
this_instance             = search("aws_opsworks_instance", "self:true").first
layer_id                  = this_instance["layer_ids"][0]
# availability_zone         = this_instance["availability_zone"]
# n = availability_zone.size
# region=availability_zone[0..n-2]
mongo_nodes = []
search("aws_opsworks_instance", "layer_ids:#{layer_id}").each do |instance|
  mongo_nodes.push(instance['hostname'])
end


cookbook_file '/tmp/dns-record.yml' do
  source 'dns-record.yml'
  owner 'root'
  group 'root'
  mode '0755'
  action :create
end

# TODO Get the node status, and exist until they all are in online state
ruby_block 'Configuring_replica_set' do
  block do
    Chef::Log.info "Replica configured == " + node['is_initiated']
    if node['is_initiated'] != ""
      master_node=`aws opsworks --region us-east-1 describe-instances --layer-id #{layer_id} --query 'Instances[0].Hostname'`.delete!("\n").delete!("\"")
      Chef::Log.info "master node " + master_node
      if master_node == this_instance["hostname"]
        Chef::Log.info "Initializing replica set"
        system("echo \"rs.initiate()\" | mongo")
        tempHash = {
            "is_initiated" => "yes",
            "HostedZoneId" => "#{node['HostedZoneId']}",
            "Name" => "#{node['Name']}"
        }
        File.open("temp.json","w") do |f|
          f.write(tempHash.to_json)
        end
        system("aws opsworks --region us-east-1 update-layer --layer-id #{layer_id} --custom-json file://temp.json")
        master_privateip=`aws opsworks --region us-east-1 describe-instances --layer-id #{layer_id} --query 'Instances[0].PrivateIp'`.delete!("\n").delete!("\"")
        master_instanceid=`aws opsworks --region us-east-1 describe-instances --layer-id #{layer_id} --query 'Instances[0].InstanceId'`.delete!("\n").delete!("\"")
        master_stackid=`aws opsworks --region us-east-1 describe-instances --layer-id #{layer_id} --query 'Instances[0].StackId'`.delete!("\n").delete!("\"")
        system("echo \"HOSTNAME=#{master_node}\" > mongo_master.dat")
        system("echo \"PRIVATE_IP=#{master_privateip}\" >> mongo_master.dat")
        system("echo \"INSTANCE_ID=#{master_instanceid}\" >> mongo_master.dat")
        system("echo \"STACK_ID=#{master_stackid}\" >> mongo_master.dat")
        system("aws s3 cp mongo_master.dat s3://#{node['config_bucket']}/")
        record_exist=`aws route53 list-resource-record-sets --hosted-zone-id #{node['HostedZoneId']} | grep #{node['Name']}.#{node['Domain']} | wc -l`.delete!("\n")
        Chef::Log.info "Checking DNS record " + record_exist
        if record_exist == "0"
          Chef::Log.info "Creating DNS Record"
          system("aws cloudformation create-stack --stack-name mongo --template-body file:///tmp/dns-record.yml --parameters \\
          ParameterKey=HostedZoneId,ParameterValue=#{node['HostedZoneId']} ParameterKey=Comment,ParameterValue=#{node['Name']} \\
          ParameterKey=PrivateIp,ParameterValue=#{master_privateip} ParameterKey=HostName,ParameterValue=#{node['Name']} \\
          ParameterKey=Domain,ParameterValue=#{node['Domain']} --region us-west-2")
        end
      end
    end
  end
end

ruby_block 'Adding_slaves' do
  block do
    mongo_nodes.each do |host|
      Chef::Log.info "Adding nodes"
      if host != this_instance["hostname"]
        system("echo \"rs.add('#{host}:27017')\" | mongo")
      end
    end
  end
end

ruby_block 'Removing unhealthy nodes' do
  block do
    command_status_of_nodes="echo \"rs.status().members\" | mongo --quiet | grep health\\\" | awk '{print $3}'"
    if `#{command_status_of_nodes}` != ""
      status_of_nodes=`#{command_status_of_nodes}`.delete!("\n").delete!(",")
      nodes=status_of_nodes.split("")
      for index_node in 0..nodes.size-1 do
        if nodes[index_node] != "1"
          Chef::Log.info "node index unhealthy " + index_node.to_s
          command="echo \"rs.status().members[#{index_node}]['name']\" | mongo --quiet"
          unhealthy_node=`#{command}`.delete!("\n")
          Chef::Log.info "deleting unhealthy node " + unhealthy_node
          system("echo 'rs.remove(\"#{unhealthy_node}\")' | mongo")
        else
          Chef::Log.info "node index healthy "  + index_node.to_s
          command="echo \"rs.status().members[#{index_node}]['name']\" | mongo --quiet"
          healthy_node=`#{command}`.delete!("\n")
          Chef::Log.info "healthy node " + healthy_node
        end
      end
    end
  end
end
