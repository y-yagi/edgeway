class TagsController < ApplicationController
  def create = render json: Tag.create!(params.require(:tag).permit(:name)), status: :created

  # PUT /tags/find_or_create: the tag with that name, made if it is not there yet.
  def find_or_create
    render json: Tag.find_or_create_by!(name: params.require(:tag).permit(:name)["name"])
  end

  def show = render json: Tag.find(params["id"])

  # PATCH /tags/rename_pair: renames two tags in one Model.batch, so D1 applies
  # both or neither. If the second name is taken (UNIQUE) the answer is 409 and
  # the first tag keeps its name too.
  def rename_pair
    pair = params.require(:rename).permit(:first_id, :first_name, :second_id, :second_name)
    first = Tag.find(pair["first_id"])
    second = Tag.find(pair["second_id"])
    Edgeway::Model.batch do
      first.update!(name: pair["first_name"])
      second.update!(name: pair["second_name"])
    end
    render json: [first, second]
  end

  def destroy
    Tag.find(params["id"]).destroy
    head :no_content
  end
end
