class Chef::Recipe::UserHelper
    def self.user_exists?(username, connection)
        begin
            connection['system.users'].find(user: username).count > 0
        rescue
            Chef::Log.info "Could not verify user existence"
        end
    end

    def self.create_admin_user(username, password, port)
        require 'mongo'

        begin
            client = Mongo::Client.new([ "127.0.0.1:#{port}" ], :database => "admin", :user => username, :password => password,:connect => "direct", :server_selection_timeout => 5)
            client.database_names
        rescue
            client = Mongo::Client.new([ "127.0.0.1:#{port}" ],:database => "admin" ,:connect => "direct", :server_selection_timeout => 5)
        end
        
        db = client.use('admin')
        roles = [{'role': 'userAdminAnyDatabase', 'db': 'admin'}, {'role': 'clusterAdmin', 'db': 'admin'}, {'role': 'dbAdminAnyDatabase', 'db': 'admin'}, {'role': 'readWriteAnyDatabase', 'db': 'admin'}]
        create_user(username, password, roles, db, client)

    end

    def self.create_user(username, password, roles, db, client)
        begin
            if !user_exists?(username, client)
            db.database.users.create(
                        username,
                        password: password,
                        roles: roles
                        )
            else
                Chef::Log.info "User " + username + " already exists"
            end
        rescue Exception => ex
            Chef::Log.info "Could not create user: " + username + ". Error: " + ex.message
        end

    end

    def self.create_all_users(users, port)
        require 'mongo'

        begin
            client = Mongo::Client.new([ "127.0.0.1:#{port}" ], :database => "admin", :user => username, :password => password,:connect => "direct", :server_selection_timeout => 5)
            client.database_names
        rescue
            client = Mongo::Client.new([ "127.0.0.1:#{port}" ],:database => "admin" ,:connect => "direct", :server_selection_timeout => 5)
        end
        
        db = client.use('admin')

        users.each do |user|
            create_user(user[:username], user[:password], user[:roles], db, client)
        end
    end
end