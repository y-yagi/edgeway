module Edgeway
  module Inflector
    # "admin_posts" -> "AdminPosts"
    def self.camelize(name) = name.split("_").map(&:capitalize).join

    # "admin/posts" -> "Admin::PostsController"
    def self.controller_class_name(path)
      path.split("/").map { |part| camelize(part) }.join("::") + "Controller"
    end

    def self.singularize(name)
      n = name.to_s
      return n[0...-3] + "y" if n.end_with?("ies")
      return n[0...-1] if n.end_with?("s")
      n
    end

    def self.pluralize(name)
      n = name.to_s
      return n[0...-1] + "ies" if n.end_with?("y") && n.length > 1 && !"aeiou".include?(n[-2])
      n + "s"
    end
  end
end
