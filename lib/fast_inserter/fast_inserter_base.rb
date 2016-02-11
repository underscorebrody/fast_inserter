# Highly based off of https://github.com/sportngin/m2m_fast_insert
# Unfortunately, that gem was not up to date for rails 4.
#
# NOTE:
#   - Only 'static_column' values and 'values' are sanitized for SQL injection.
#
# Example usage:
#   @mass_email = MassEmail.find(params[:id])
#   user_ids = [1, 2, 3, 4] # ids to fast insert
#   params = {
#     table: 'mass_emails_users',
#     static_columns: {
#       mass_email_id: @mass_email.id
#     },
#     additional_columns: {
#       created_by_id: current_user.id
#     },
#     timestamps: true,
#     unique: true,
#     check_for_existing: true,
#     variable_column: 'user_id',
#     values: user_ids
#   }
#   inserter = FastInserter::Base.new(params)
#   inserter.fast_insert
#
# Options:
#   unique: true
#     Makes sure all values are unique
#   check_for_existing: true
#     Checks if values already exist in the database and only inserts nonexisting values
#     This checks values scoped to static columns.
#   timestamps: true
#     Adds created_at and updated_at columns to insert statement
#   additional_columns: Hash
#     A hash representing additional column values to set that you don't want
#     to include in uniqueness checks or other pre-insertion operations.
#
module FastInserter
  class Base
    def initialize(params)
      @table_name = params[:table]
      @static_columns = params[:static_columns]
      @additional_columns = params[:additional_columns]
      @variable_column = params[:variable_column]
      @options = params[:options] || {}

      # We want to break up the insertions into multiple transactiosn in case there
      # is a very large amount of values. This avoids PG:OutOfMemory errors and smooths
      # out the load. The second 'false' param means don't fill in the last group with nil elements.
      all_values = params[:values]
      all_values.uniq! if @options[:unique]
      group_size = Integer(params[:group_size] || 10_000)
      @value_groups = all_values.in_groups_of(group_size, false)
    end

    # Iterates through the value groups (which is all values in groups of smaller sizes)
    # and generates and executes a transaction to insert those groups one at a time
    def fast_insert
      return if nothing_to_insert?

      @value_groups.each do |group|
        fast_insert_group(group)
      end
    end

  private

    def nothing_to_insert?
      @value_groups.empty?
    end

    # For a given group of IDS, generates the transaction to execute and does. If we want to check existing
    # we make sure that we check the existing within the same transaction.
    def fast_insert_group(group)
      if @options[:check_for_existing]
        ActiveRecord::Base.transaction do
          non_existing_values = group.map(&:to_s) - existing_values(group)
          sql_string = insertion_sql_for_group(non_existing_values)
          ActiveRecord::Base.connection.execute(sql_string) unless non_existing_values.empty?
        end
      else
        sql_string = insertion_sql_for_group(group)
        ActiveRecord::Base.connection.execute(sql_string)
      end
    end

    # Queries for the existing values for a given group of values
    def existing_values(group_of_values)
      values_to_check = ActiveRecord::Base.send(:sanitize_sql_array, ["?", group_of_values])
      sql = "SELECT #{@variable_column} FROM #{@table_name} WHERE #{existing_values_static_columns} AND #{@variable_column} IN (#{values_to_check})"
      ActiveRecord::Base.connection.execute(sql).field_values(@variable_column)
    end

    def existing_values_static_columns
      @static_columns.map do |key, value|
        sanitized_value = ActiveRecord::Base.send(:sanitize_sql_array, ["?", value])
        "#{key} = #{sanitized_value}"
      end.join(' AND ')
    end

    def insertion_sql_for_group(group_of_values)
      "INSERT INTO #{@table_name} (#{column_names}) VALUES #{insert_values(group_of_values)}"
    end

    def column_names
      "#{all_static_columns.keys.join(', ')}, #{@variable_column}"
    end

    def all_static_columns
      @all_static_columns ||= begin
        rv = @static_columns.dup

        if @options[:timestamps]
          time = Time.now
          rv[:created_at] = time
          rv[:updated_at] = time
        end

        if @additional_columns.present?
          @additional_columns.each do |key, value|
            rv[key] = value
          end
        end

        rv
      end
    end

    def insert_values(group_of_values)
      rv = []
      static_column_values = ActiveRecord::Base.send(:sanitize_sql_array, ["?", all_static_columns.values])

      group_of_values.each do |value|
        value = ActiveRecord::Base.send(:sanitize_sql_array, ["?", value])
        rv << "(#{static_column_values},#{value})"
      end

      rv.join(', ')
    end
  end
end