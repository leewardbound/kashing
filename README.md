## Kashing plugin for Rails 3

A functional, additive approach to model-based Rails 3 caching with Redis.

Usage is designed to be simple:

```ruby
  class RocketShip < ActiveRecord::Base
    # Add Kashing to existing fields
    # Cached values are JSON serialized then saved into Redis
    kashing :title  

    # You can even define a function, letting you add Kashing almost anywhere
    kashing :people_on_board do self.riders.map {|p| p.name } end 

    # Use a custom TTL
    kashing :time_since_launch, :ttl => 10 do
      puts "Recalculating time since launch..."
      (Time.now - self.launched_at).to_i
    end 
  end
```

Here's how we use it after it's been added to the model

```ruby
# Setup our rocketship
r=RocketShip.new :title => 'Admiral Nelson', :launched_at = Time.now
r.riders += User.first

r.launched_at
#=> Mon Jan 17 18:52:31 -0800 2011
r.save

# Let's show SQL queries, so we know what's being cached
ActiveRecord::Base.logger = Logger.new STDOUT

# Using Kashing --
r = RocketShip.first
# RocketShip Load (0.6ms) SELECT `rocketship`.* from `rocketships` LIMIT 1

r.title_kashing # Get the Kash value by adding "_kashing"
#=> 'Admiral Nelson' 

RocketShip.first_name_kashing(1) # Find it by ID
#=> 'Admiral Nelson'

RocketShip.clear_first_name(1) # If the value isn't found in the kash
#=> nil

RocketShip.first_name_kashing(1) # Kashing will load the object
# RocketShip Load (0.6ms) SELECT `rocketship`.* from `rocketships` LIMIT 1
#=> 'Admiral Nelson'

r.launched_at_kashing # Use :time => true for Time values
#=> Mon Jan 17 18:52:31 -0800 2011

r.people_on_board_kashing # The first time will hit the database
#User Load (0.6ms) SELECT `user`.* from `users` WHERE (`user`.`id` IN (1))
#=> ['Fred']

r.people_on_board_kashing # But subsequent calls will not!
#=> ['Fred']
r.riders.delete_all 
r.people_on_board_kashing # Be careful of this!
#=> ['Fred']
r.clear_people_on_board # Clear the Kashing value for :people_on_board
r.people_on_board_kashing
#User Load (0.6ms) SELECT `user`.* from `users` WHERE (`user`.`id` IN (1))
#=> []

r.time_since_launch_kashing.to_i # Suppose we launched 3s ago
# Recalculating time since launch...
#=> 3 
Time.sleep(5)
r.time_since_launch_kashing.to_i # TTL has not expired yet, still "3"
#=> 3
Time.sleep(10)
r.time_since_launch_kashing.to_i # We launched 18s ago
# Recalculating time since launch...
#=> 18
