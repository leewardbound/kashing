#
#  Kashing Plugin for Rails 3
#  Leverages Redis to provide flexible
#  model kashing options
#
#  class RocketShip < ActiveRecord::Base
#    # Add Kashing to existing fields
#    kashing :title  
#
#    # Cached values are JSON serialized then saved into Redis, and deserialized
#    # when retrieved. If you don't use :time => true, or specify a custom
#    # parser/packer, then your field will be retrieved as a String
#    kashing :launched_at, :time => true  
#
#    # You can even define a function, letting you add Kashing almost anywhere
#    kashing :people_on_board do self.riders.map {|p| p.name } end 
#
#    # Use a custom TTL
#    kashing :time_since_launch, :ttl => 10 do
#      puts "Recalculating time since launch..."
#      (Time.now - self.launched_at).to_i
#    end
#
#    # If you need to do fast, class-based lookups
#    # for cached values, disable auto-loading
#    # and enable the class methods
#    kashing :price, :no_auto => true, :class_method => true
#    # Use it like: RocketShip.price_kashing(id)
#  end

module KashingPlugin
  @@redis_client = false
  def self.redis
    if not @@redis_client
      uri = URI.parse(ENV["REDISTOGO_URL"] || ENV["REDIS_URL"] || 'redis://localhost:6379')
      @@redis_client = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password,
        :db => ENV["REDIS_DB_NUM"].to_i)
    end
    return @@redis_client
  end

  def self.included(base)
    base.send :extend, ClassMethods
  end

  module ClassMethods
    def metaclass
     class << self
       self
     end
   end

   # Evaluates the block in the context of the metaclass
   def meta_eval &blk
     metaclass.instance_eval &blk
   end

    # Adds method "kashing" to models
    def kashing(name, options=false, &block)
      # Share a redis connections
      mattr_accessor :redis
      @@redis ||= Redis.new
      options ||= {}

      # per-model self.kashing_fields to store metadata
      class_inheritable_accessor :kashing_fields

      # def Model.field_name_kashing(id) shortcut
      class_method_shortcut(name)

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
      
      self.kashing_fields[name] = {
        :default_ttl => options[:ttl] || false,
        :parse => options[:parse] || false,
        :store => options[:store] || false,
        :func => func,
        :options => options
      }
    end

    def class_kashing(name, options=false, &block)
      class_inheritable_accessor :kashing_fields
      # Share a redis connections
      mattr_accessor :redis
      @@redis ||= Redis.new
      options ||= {}
      if not block_given?
        raise "class_kashing called without a block"
      end
      self.kashing_fields ||= {}
      self.kashing_fields[name] = {
        :default_ttl => options[:ttl] || false,
        :parse => options[:parse] || false,
        :store => options[:store] || false,
        :func => block,
        :options => options
      }
      meta_eval {
        define_method "#{name}_kashing" do
            self.smart_kash(0,name)
        end
        define_method "clear_#{name}" do
            self.clear_kash(0,name)
        end
      }
    end

    def kash_key_name(id, name)
      "#{self.name}_#{id}_#{name}"
    end

    def kash_meta(name)
      begin
        self.kashing_fields[name]
      rescue
        false
      end
    end
    def kash_options(name)
      kash_meta(name)[:options]
    end

    def kashed_value_for(id, name)
      class_inheritable_accessor :kashing_fields
      name = name.to_sym
      v = KashingPlugin.redis.get(kash_key_name(id, name))
      begin
        parse = self.kashing_fields[name][:parse]
        if parse then return parse.call(v) end
        v = ActiveSupport::JSON.decode(v)
        if 0 == (v =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}-\d{2}:\d{2}/)
          v = Time.zone.parse(v)
        end
      rescue e
        puts e
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
    def set_class_kash_for(name)
      name = name.to_sym
      c = self.kashing_fields[name]
      return false if not c
      func_return = c[:func].call(self)
      if c[:store]
          value = c[:store].call(func_return)
      else
        value = ActiveSupport::JSON.encode(func_return)
      end

      KashingPlugin.redis.set(kash_key_name(0, name), value)
      if self.kash_options(name)[:default_ttl]
        self.clear_kash(0, name, self.kash_options(name)[:default_ttl])
      end
      kashed_value_for(0, name)
    end
    def smart_kash(id, name)
      v = kashed_value_for(id, name)
      if not v and not kash_options(name)[:no_auto]
        if id != 0
          c = Object.const_get(self.name).find(id)
          v = c.set_kash_for(name)
        else
          v = set_class_kash_for(name)
        end
      end
      v
    end


    private
      def class_method_shortcut(name)
        meta_eval {
          define_method "#{name}_kashing" do |id|
              self.smart_kash(id,name)
          end
        }
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
      func_return = c[:func].call(self)
      if c[:store]
          value = c[:store].call(func_return)
      else
        value = ActiveSupport::JSON.encode(func_return)
      end

      KashingPlugin.redis.set(kash_key_name(name), value)
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
