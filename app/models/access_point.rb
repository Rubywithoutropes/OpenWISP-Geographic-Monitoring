# This file is part of the OpenWISP Geographic Monitoring
#
# Copyright (C) 2012 OpenWISP.org
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

class AccessPoint < ActiveRecord::Base
  require 'ipaddr'

  acts_as_authorization_object
  acts_as_mappable :default_units => :kms

  # pagination is handled by kaminari (gem)
  paginates_per CONFIG['default_pagination']
  CLUSTER_ACCESS_POINTS_WITHIN_KM = 2

  belongs_to :wisp
  has_one :property_set, :autosave => true, :dependent => :destroy
  has_many :activities
  has_many :activity_histories
  has_many :associated_user_counts
  has_many :associated_user_count_histories

  def coords
    [lat, lng]
  end

  def site
    base = site_description.present? ? "#{site_description} - " : ""
    base << city
  end

  def ip
    mng_ip.nil? ? nil : IPAddr.new(read_attribute(:mng_ip), Socket::AF_INET).to_s
  end

  def favourite?
    favourite == true or favourite == '1'
  end

  def up?
    self.reachable == true or self.reachable == '1'
  end

  def down?
    self.reachable == false or self.reachable == '0'
  end

  def unknown?
    self.reachable.nil?
  end

  def known?
    !unknown?
  end
  
  def public?
    self.public == true or self.public == '1'
  end

  def status
    if unknown?
      -1
    elsif up?
      1
    elsif down?
      0
    end
  end

  def reachable!
    set_reachable_to true
  end

  def unreachable!
    set_reachable_to false
  end

  def latest_seen
    unless unknown?
      latest = activity_histories.last :conditions => ["status > ?", 0], :order => "last_time ASC"
      latest.nil? ? '-' : latest.last_time
    end
  end

  def earliest_seen
    unless unknown?
      earliest = activity_histories.first :conditions => ["status > ?", 0], :order => "last_time ASC"
      earliest.nil? ? '-' : earliest.last_time
    end
  end

  def up_average(from, to)
    sprintf "%.1f", activity_histories.observe(activation_date > from ? activation_date : from, to).average_availability
  end

  def down_average(from, to)
    sprintf "%.1f", 100 - activity_histories.observe(activation_date > from ? activation_date : from, to).average_availability
  end

  def associated_users(scope = :all)
    AssociatedUser.active_resource_from(wisp.owmw_url, wisp.owmw_username, wisp.owmw_password)
    AssociatedUser.find(scope, :params => {:access_point => hostname})
  end

  def properties
    property_set.nil? ? build_property_set : property_set
  end
  
  # this must be called only after fetching from db by using with_properties_and_group method
  def build_property_set_if_group_name_empty
    if self.group_name.nil?
      properties = self.properties
      properties.save!
      self.group_name = properties.group.name
    end
  end

  ##### Static methods #####

  def self.draw_map
    clustered_access_points = []
    already_clustered = []

    find_each do |hs|
      cluster = around(hs.coords)
      cluster -= already_clustered

      clustered_access_points << ( cluster.count > 1 ? Cluster.new(cluster) : cluster.first )

      already_clustered += cluster
    end

    clustered_access_points
  end

  def self.of_wisp(wisp)
    # Skip scope (and let other scopes return results) if wisp is nil
    wisp ? where(:wisp_id => wisp.id) : scoped
  end

  def self.sort_with(attribute='id', direction='asc')
    attribute = attribute.nil? ? 'id' : attribute
    direction = direction.nil? ? 'asc' : direction
    case attribute
      when 'status' then
        order("`reachable` #{direction}")
      when 'public' then
        order("`public` #{direction}")
      when 'site_description' then
        order("`site_description` #{direction}")
      when 'favourite' then
        # invert
        direction = direction == 'asc' ? 'desc' : 'asc'
        order("`favourite` #{direction}")
      when 'mac_address' then
        order("`common_name` #{direction}")
      when 'ip_address' then
        order("`mng_ip` #{direction}")
      when 'group' then
        order("`group_name` #{direction}")
      else
        order("#{attribute} #{direction}")
    end
  end

  def self.around(coords)
    select("`access_points`.*").geo_scope(:within => CLUSTER_ACCESS_POINTS_WITHIN_KM, :origin => coords)
  end

  def self.on_georss
    with_properties.where(:property_sets => {:public => true})
  end

  def self.up
    with_properties_and_group.where('groups.count_stats IS NULL OR groups.count_stats = 1').where(:property_sets => {:reachable => true})
  end

  def self.down
    with_properties_and_group.where('groups.count_stats IS NULL OR groups.count_stats = 1').where(:property_sets => {:reachable => false})
  end

  def self.known
    with_properties_and_group.where('groups.count_stats IS NULL OR groups.count_stats = 1').where(:property_sets => {:reachable => [true, false]})
  end

  def self.unknown
    with_properties_and_group.where('groups.count_stats IS NULL OR groups.count_stats = 1').where(:property_sets => {:reachable => nil})
  end
  
  def self.total
    with_properties_and_group.where('groups.count_stats IS NULL OR groups.count_stats = 1')
  end
  
  def self.favourite(action=:total, wisp=nil, group=nil)
    where_condition = { :property_sets => { :favourite => 1 } }
    
    case action
    when :up
      where_condition[:property_sets][:reachable] = true
    when :down
      where_condition[:property_sets][:reachable] = false
    when :known
      where_condition[:property_sets][:reachable] = [true, false]
    when :unknown
      where_condition[:property_sets][:reachable] = nil
    when :total
      # pass
    else
      raise ArgumentError, 'unknown action argument "%s", can be only "total", "up", "down", "unknown" or "known"' % action
    end
    
    unless wisp.nil?
      # if it's wisp instance call instance.id
      where_condition[:wisp_id] = wisp.class == Wisp ? wisp.id : wisp
    end
    
    unless group.nil?
      # if it's group instance call instance.id
      where_condition[:property_sets][:group_id] = group.class == Group ? group.id : group
      
      return with_properties_and_group.where(where_condition)
    else
      return with_properties.where(where_condition)
    end
  end


  def self.activated(till=nil)
    where("activation_date <= ?", till)
  end

  def self.all_up(regex=nil)
    AccessPoint.up.hostname_like regex
  end

  def self.all_down(regex=nil)
    AccessPoint.down.hostname_like regex
  end

  def self.all_unknown(regex=nil)
    AccessPoint.unknown.hostname_like regex
  end

  def self.hostname_like(name)
    where("`hostname` LIKE ?", "%#{name}%")
  end

  def self.quicksearch(name)
    where("`hostname` LIKE ? OR `address` LIKE ? OR `city` LIKE ? OR `common_name` LIKE ? OR `mng_ip` LIKE ? OR `site_description` LIKE ?", *(["%#{name}%"]*6) )
  end
  
  # update all property sets specified in id_array and set the specified group_id
  def self.batch_change_group(id_array, group_id)
    where = "access_point_id IN ("
    # build where clause
    id_array.each { where << "?, " }
    # remove last two characters ", " and add the last parenthesis
    where = "%s)" % where[0, where.length-2]
    conditions = [where] + id_array
    PropertySet.update_all({ :group_id => group_id }, conditions)
  end
  
  # update all property sets specified in id_array and
  # set the specified property "name" to the specified "value"
  def self.batch_change_property(id_array, name, value)
    where = "access_point_id IN ("
    # build where clause
    id_array.each { where << "?, " }
    # remove last two characters ", " and add the last parenthesis
    where = "%s)" % where[0, where.length-2]
    conditions = [where] + id_array
    PropertySet.update_all({ name.to_sym => value }, conditions)
  end
  
  def self.build_all_properties
    with_properties_and_group.each do |ap|
      ap.build_property_set_if_group_name_empty
    end
  end

  def self.filter_favourites(condition)
    where(:property_sets => {:favourite => condition})
  end

  private

  # select access_points left join property_sets
  def self.with_properties(select_fields=nil)
    # select almost all the attributes by default
    # exclude property_sets.id and property_sets.access_point_id because of rare use
    if select_fields.nil?
      select_fields = "access_points.*, property_sets.reachable, property_sets.public, property_sets.site_description,
      property_sets.category, property_sets.group_id, property_sets.favourite, property_sets.notes"
    end
    select(select_fields).joins("LEFT JOIN `property_sets` ON `property_sets`.`access_point_id` = `access_points`.`id`")
  end
  
  # select access_points left join property_sets and groups
  def self.with_properties_and_group(additional_fields=nil)
    # select almost all the attributes by default
    # exclude property_sets.id and property_sets.access_point_id because of rare use
    
    # the default behaviour with the group table is to include only group_name
    select_fields = "access_points.*, property_sets.reachable, property_sets.public, property_sets.site_description,
      property_sets.category, property_sets.group_id, property_sets.favourite, property_sets.notes, groups.name AS group_name"
    
    unless additional_fields.nil?
      select_fields = "#{select_fields}, #{additional_fields}"
    end
    
    select(select_fields).joins("LEFT JOIN `property_sets` ON `property_sets`.`access_point_id` = `access_points`.`id`
          LEFT JOIN `groups` ON `property_sets`.`group_id` = `groups`.`id`")
  end


  def set_reachable_to(boolean)
    property_set.update_attribute(:reachable, boolean) rescue PropertySet.create(:reachable => boolean, :access_point => self)
  end
end
