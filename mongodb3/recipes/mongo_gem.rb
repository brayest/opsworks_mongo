# install the mongo ruby gem at compile time to make it globally available
chef_gem 'mongo' do
  action :install
end
Chef::Log.warn("Installing mongo")
chef_gem 'bson_ext' do
  action :install
end
Chef::Log.warn("Installing BSON")
