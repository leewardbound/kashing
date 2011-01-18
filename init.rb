#
#  Kashing Plugin for Rails 3
#  Leverages Redis to provide flexible
#  model kashing options
#

module KashingPlugin
  @@redis_client = false
  def self.redis
    if not @@redis_client
      uri = URI.parse (ENV["REDISTOGO_URL"] || ENV["REDIS_URL"] || 'redis://localhost:6379')
      @@redis_client = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password,
        :db => ENV["REDIS_DB_NUM"].to_i)
    end
    return @@redis_client
  end

  def self.included(base)
    base.send :extend, ClassMethods
  end
  module ClassMethods
    # Adds method "kashing" to models
    def kashing(name, options = {}, &block)
      # Share a redis connections
      mattr_accessor :redis
      @@redis ||= Redis.new

      # per-model self.kashing_fields to store metadata
      class_inheritable_accessor :kashing_fields


      # attach to the class
      if !method_defined?(:kash_initialize)
        include InstanceMethods
        after_save :update_kash
        before_destroy :clear_kash
        before_create :clear_kash
        define_method "#{name}_kashing" do smart_kash(name) end
        define_method "expire_#{name}" do |ttl| 
          ttl ||= 0
          clear_kash(name, ttl)
        end
        define_method "clear_#{name}" do clear_kash(name, 0) end
      end

      # The value to be stored
      if not block_given? then
        func = Proc.new { |inst| inst.send(name) }
      else
        func = Proc.new { |inst| inst.instance_eval &block }
      end
      self.kashing_fields ||= {}
      
      # Unpack the time fields
      if options[:time] == true
        parse = lambda {|s| Time.parse s }
        store = lambda {|s| s.strftime '%Y-%m-%d %H:%M:%S GMT%z' }
      end
      self.kashing_fields[name] = {
        :default_ttl => options[:ttl] || false,
        :parse => parse || false,
        :store => store || false,
        :func => func,
        :options => options
      }
    end

    def kash_key_name(id, name)
      "#{self.name}_#{id}_#{name}"
    end

    def kashed_value_for(id, name)
      class_inheritable_accessor :kashing_fields
      name = name.to_sym
      v = KashingPlugin.redis.get(kash_key_name(id, name))
      begin
        parse = self.kashing_fields[name][:parse]
        if parse then v = parse.call(v)
        else v = JSON.parse(v)
        end
      ensure
        return v
      end
    end

    def expire_kash(id, name, ttl)
      key_name = kash_key_name(id, name)
      if not KashingPlugin.redis.expire(key_name, ttl)
        if ttl == 0 then return KashingPlugin.redis.del(key_name) end
        v = KashingPlugin.redis.get(key_name)
        KashingPlugin.redis.set(key_name, v)
        KashingPlugin.redis.expire(key_name, ttl)
      end
    end
    def clear_kash(id, name=false, ttl=0)
      if name
        expire_kash(id, name, ttl) and true
      else
        class_inheritable_accessor :kashing_fields
        self.kashing_fields.each { |name, o|
          expire_kash(id, name, ttl) }
        true
      end
    end
    def smart_kash(id, name)
      v = kashed_value_for(id, name)
      if not v
        c = Object.const_get(self.name).find(id)
        v = c.set_kash_for(name)
      end
      v
    end
  end

  module InstanceMethods
    attr_accessor :kashing_ttls
    def kash_key_name(name)
      self.class.kash_key_name(self.id, name)
    end

    def kashed_value_for(name)
      self.class.kashed_value_for(self.id, name)
    end

    def set_kash_for(name)
      name = name.to_sym
      c = self.kashing_fields[name]
      return false if not c
      value = c[:func].call(self)
      begin
        value = c[:store].call(value) if c[:store]
      rescue
      end

      KashingPlugin.redis.set(kash_key_name(name), value.to_json)
      c[:type] = value.class
      if self.kash_ttl(name)
        self.clear_kash(name, self.kash_ttl(name))
      end
      kashed_value_for(name)
    end

    def set_kash_ttl_for(name, ttl)
      self.kashing_ttls ||= {}
      self.kashing_ttls[name] = ttl
    end

    def kash_ttl(name)
      # per-object TTL support
      self.kashing_ttls ||= {}
      self.kashing_ttls[name] ||= self.kashing_fields[name][:default_ttl]
    end
    def smart_kash(name)
      kashed_value_for(name) || set_kash_for(name)
    end
    def update_kash
      self.kashing_fields.each { |name, o| set_kash_for(name) }
    end
    def clear_kash(name=false, ttl=0)
      self.class.clear_kash(self.id, name, ttl)
    end
  end
end

ActiveRecord::Base.extend(KashingPlugin::ClassMethods)
