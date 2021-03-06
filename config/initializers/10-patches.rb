#-- encoding: UTF-8
#-- copyright
# ChiliProject is a project management system.
#
# Copyright (C) 2010-2011 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# See doc/COPYRIGHT.rdoc for more details.
#++


require 'active_record'

# Backported fix for CVE-2012-3465
# https://groups.google.com/d/msg/rubyonrails-security/FgVEtBajcTY/tYLS1JJTu38J
# TODO: Remove this once we are on Rails >= 3.2.8
require 'action_view/helpers/sanitize_helper'
module ActionView::Helpers::SanitizeHelper
  def strip_tags(html)
    self.class.full_sanitizer.sanitize(html)
  end
end

# Backported fix for CVE-2012-3464
# https://groups.google.com/d/msg/rubyonrails-security/kKGNeMrnmiY/r2yM7xy-G48J
# TODO: Remove this once we are on Rails >= 3.2.8
require 'active_support/core_ext/string/output_safety'
class ERB
  module Util
    HTML_ESCAPE["'"] = '&#39;'

    if RUBY_VERSION >= '1.9'
      # A utility method for escaping HTML tag characters.
      # This method is also aliased as <tt>h</tt>.
      #
      # In your ERB templates, use this method to escape any unsafe content. For example:
      # <%=h @person.name %>
      #
      # ==== Example:
      # puts html_escape("is a > 0 & a < 10?")
      # # => is a &gt; 0 &amp; a &lt; 10?
      def html_escape(s)
        s = s.to_s
        if s.html_safe?
          s
        else
          s.gsub(/[&"'><]/, HTML_ESCAPE).html_safe
        end
      end
    else
      def html_escape(s) #:nodoc:
        s = s.to_s
        if s.html_safe?
          s
        else
          s.gsub(/[&"'><]/n) { |special| HTML_ESCAPE[special] }.html_safe
        end
      end
    end

    # Aliasing twice issues a warning "discarding old...". Remove first to avoid it.
    remove_method(:h)
    alias h html_escape

    module_function :h

    singleton_class.send(:remove_method, :html_escape)
    module_function :html_escape
  end
end


require 'action_view/helpers/tag_helper'
module ActionView::Helpers::TagHelper
  def escape_once(html)
    ActiveSupport::Multibyte.clean(html.to_s).gsub(/[\"\'><]|&(?!([a-zA-Z]+|(#\d+));)/) { |special| ERB::Util::HTML_ESCAPE[special] }
  end
end


module ActiveRecord
  class Base
    include Redmine::I18n

    # Translate attribute names for validation errors display
    def self.human_attribute_name(attr)
      l("field_#{attr.to_s.gsub(/_id$/, '')}")
    end

    # Backported fix for
    # CVE-2013-0155
    # https://groups.google.com/forum/?hl=en&fromgroups=#!topic/rubyonrails-security/c7jT-EeN9eI
    protected
    class << self
      def sanitize_sql_hash_for_conditions(attrs, default_table_name = quoted_table_name, top_level = true)
        attrs = expand_hash_conditions_for_aggregates(attrs)

        return '1 = 2' if !top_level && attrs.is_a?(Hash) && attrs.empty?

        conditions = attrs.map do |attr, value|
          table_name = default_table_name

          if not value.is_a?(Hash)
            attr = attr.to_s

            # Extract table name from qualified attribute names.
            if attr.include?('.') and top_level
              attr_table_name, attr = attr.split('.', 2)
              attr_table_name = connection.quote_table_name(attr_table_name)
            else
              attr_table_name = table_name
            end

            attribute_condition("#{attr_table_name}.#{connection.quote_column_name(attr)}", value)
          elsif top_level
            sanitize_sql_hash_for_conditions(value, connection.quote_table_name(attr.to_s), false)
          else
            raise ActiveRecord::StatementInvalid
          end
        end.join(' AND ')

        replace_bind_variables(conditions, expand_range_bind_variables(attrs.values))
      end
    end
  end
end

module ActiveRecord
  class Errors
    def full_messages(options = {})
      full_messages = []

      @errors.each_key do |attr|
        @errors[attr].each do |message|
          next unless message

          if attr == "base"
            full_messages << message
          elsif attr == "custom_values"
            # Replace the generic "custom values is invalid"
            # with the errors on custom values
            @base.custom_values.each do |value|
              value.errors.each do |attr, msg|
                full_messages << value.custom_field.name + ' ' + msg
              end
            end
          else
            attr_name = @base.class.human_attribute_name(attr)
            full_messages << attr_name + ' ' + message.to_s
          end
        end
      end
      full_messages
    end
  end
end

module ActionView
  module Helpers
    module AccessibleErrors

      def self.included(base)
        base.send(:include, InstanceMethods)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def wrap_with_error_span(html_tag, object, method)
          object_identifier = erroneous_object_identifier(object.object_id.to_s, method)

          "<span id='#{object_identifier}' class=\"errorSpan\"><a name=\"#{object_identifier}\"></a>#{html_tag}</span>"
        end

        def erroneous_object_identifier(id, method)
          # select boxes use name_id whereas the validation uses name
          # we have to cut the '_id' of in order for the field to match
          id + "_" + method.gsub("_id", "") + "_error"
        end
      end

      module InstanceMethods

        def error_message_list(objects)
          objects.collect do |object|
            error_messages = []

            object.errors.each_error do |attr, error|
              unless attr == "custom_values"
                # Generating unique identifier in order to jump directly to the field with the error
                object_identifier = erroneous_object_identifier(object.object_id.to_s, attr)

                error_messages << [object.class.human_attribute_name(attr) + " " + error.message, object_identifier]
              end
            end

            # excluding custom_values from the errors.each loop before
            # as more than one error can be assigned to custom_values
            # which would add to many error messages
            if object.errors.on(:custom_values)
              object.custom_values.each do |value|
                value.errors.collect do |attr, msg|
                  # Generating unique identifier in order to jump directly to the field with the error
                  object_identifier = erroneous_object_identifier(value.object_id.to_s, attr)
                  error_messages << [value.custom_field.name + " " + msg, object_identifier]
                end
              end
            end

            error_message_list_elements(error_messages)
          end
        end

        private

        def erroneous_object_identifier(id, method)
          self.class.erroneous_object_identifier(id, method)
        end

        def error_message_list_elements(array)
          array.collect do |msg, identifier|
            content_tag :li do
              content_tag :a,
                          ERB::Util.html_escape(msg),
                          :href => "#" + identifier,
                          :class => "afocus"
            end
          end
        end
      end
    end


    module ActiveRecordHelper
      def error_messages_for(*params)
        options = params.extract_options!.symbolize_keys

        if object = options.delete(:object)
          objects = Array.wrap(object)
        else
          objects = params.collect {|object_name| instance_variable_get("@#{object_name}") }.compact
        end

        count  = objects.inject(0) {|sum, object| sum + object.errors.count }
        unless count.zero?
          html = {}
          [:id, :class].each do |key|
            if options.include?(key)
              value = options[key]
              html[key] = value unless value.blank?
            else
              html[key] = 'errorExplanation'
            end
          end
          options[:object_name] ||= params.first

          I18n.with_options :locale => options[:locale], :scope => [:activerecord, :errors, :template] do |locale|
            header_message = if options.include?(:header_message)
              options[:header_message]
            else
              object_name = options[:object_name].to_s
              object_name = I18n.t(object_name, :default => object_name.gsub('_', ' '), :scope => [:activerecord, :models], :count => 1)
              locale.t :header, :count => count, :model => object_name
            end
            message = options.include?(:message) ? options[:message] : locale.t(:body)

            contents = ''
            contents << content_tag(options[:header_tag] || :h2, header_message) unless header_message.blank?
            contents << content_tag(:p, message) unless message.blank?
            contents << content_tag(:ul, error_message_list(objects))

            content_tag(:div, contents.html_safe, html)
          end
        else
          ''
        end
      end
    end

    module DateHelper
      # distance_of_time_in_words breaks when difference is greater than 30 years
      def distance_of_date_in_words(from_date, to_date = 0, options = {})
        from_date = from_date.to_date if from_date.respond_to?(:to_date)
        to_date = to_date.to_date if to_date.respond_to?(:to_date)
        distance_in_days = (to_date - from_date).abs

        I18n.with_options :locale => options[:locale], :scope => :'datetime.distance_in_words' do |locale|
          case distance_in_days
            when 0..60     then locale.t :x_days,             :count => distance_in_days.round
            when 61..720   then locale.t :about_x_months,     :count => (distance_in_days / 30).round
            else                locale.t :over_x_years,       :count => (distance_in_days / 365).floor
          end
        end
      end
    end
  end
end

ActionView::Base.send :include, ActionView::Helpers::AccessibleErrors

ActionView::Base.field_error_proc = Proc.new do |html_tag, instance|
  if html_tag.include?("<label")
    html_tag.to_s
  else
    ActionView::Base.wrap_with_error_span(html_tag, instance.object, instance.method_name)
  end
end

class ActiveRecord::Errors
  def on_with_id_handling(attribute)
    attribute = attribute.to_s
    if attribute.ends_with? '_id'
      on_without_id_handling(attribute) || on_without_id_handling(attribute[0..-4])
    else
      on_without_id_handling(attribute)
    end
  end

  alias_method_chain :on, :id_handling
end

# Adds :async_smtp and :async_sendmail delivery methods
# to perform email deliveries asynchronously
module AsynchronousMailer
  %w(smtp sendmail).each do |type|
    define_method("perform_delivery_async_#{type}") do |mail|
      Thread.start do
        send "perform_delivery_#{type}", mail
      end
    end
  end
end

ActionMailer::Base.send :include, AsynchronousMailer

# TMail::Unquoter.convert_to_with_fallback_on_iso_8859_1 introduced in TMail 1.2.7
# triggers a test failure in test_add_issue_with_japanese_keywords(MailHandlerTest)
module TMail
  class Unquoter
    class << self
      alias_method :convert_to, :convert_to_without_fallback_on_iso_8859_1
    end
  end
end

module ActionController
  module MimeResponds
    class Responder
      def api(&block)
        any(:xml, :json, &block)
      end
    end
  end

  # Backported fix for
  # CVE-2012-2660
  # https://groups.google.com/group/rubyonrails-security/browse_thread/thread/f1203e3376acec0f
  #
  # CVE-2012-2694
  # https://groups.google.com/group/rubyonrails-security/browse_thread/thread/8c82d9df8b401c5e
  #
  # TODO: Remove this once we are on Rails >= 3.2.6
  require 'action_controller/request'
  class Request
    protected

    # Remove nils from the params hash
    def deep_munge(hash)
      keys = hash.keys.find_all { |k| hash[k] == [nil] }
      keys.each { |k| hash[k] = nil }

      hash.each_value do |v|
        case v
        when Array
          v.grep(Hash) { |x| deep_munge(x) }
          v.compact!
        when Hash
          deep_munge(v)
        end
      end

      hash
    end

    def parse_query(qs)
      deep_munge(super)
    end
  end
end
