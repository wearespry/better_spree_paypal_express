module Spree
  class PaypalController < StoreController

    def express
      order = current_order || raise(ActiveRecord::RecordNotFound)
      items = order.line_items.map(&method(:line_item))

      additional_adjustments = order.all_adjustments.additional
      tax_adjustments = additional_adjustments.tax
      shipping_adjustments = additional_adjustments.shipping

      additional_adjustments.eligible.each do |adjustment|

        logger.info 'Adjustment total: '+adjustment.amount.to_s.to_yaml

        # Because PayPal doesn't accept $0 items at all. See #10
        # https://cms.paypal.com/uk/cgi-bin/?cmd=_render-content&content_ID=developer/e_howto_api_ECCustomizing
        # "It can be a positive or negative value but not zero."
        next if adjustment.amount.zero?
        next if tax_adjustments.include?(adjustment) || shipping_adjustments.include?(adjustment)

        items << {
          Name: adjustment.label,
          Quantity: 1,
          Amount: {
            currencyID: order.currency,
            value: adjustment.amount
          }
        }
      end

      logger.info ''
      logger.info 'Order total: '+order.total.to_f.to_s
      logger.info ''

      pp_request = provider.build_set_express_checkout(express_checkout_request_details(order, items))

      logger.info ''
      logger.info 'PP Request: '
      logger.info ''
      logger.info pp_request.SetExpressCheckoutRequestDetails.PaymentDetails.to_yaml

      begin
        pp_response = provider.set_express_checkout(pp_request)
        if pp_response.success?
          redirect_to provider.express_checkout_url(pp_response, useraction: 'commit')
        else

          logger.info pp_response.errors

          flash[:error] = Spree.t('flash.generic_error', scope: 'paypal', reasons: pp_response.errors.map(&:long_message).join(" "))
          redirect_to checkout_state_path(:payment)
        end
      rescue SocketError
        flash[:error] = Spree.t('flash.connection_failed', scope: 'paypal')
        redirect_to checkout_state_path(:payment)
      end
    end

    def confirm
      # order = current_order || raise(ActiveRecord::RecordNotFound)

      order = Spree::Order.last

      order.payments.create!({
        source: Spree::PaypalExpressCheckout.create({
          token: params[:token],
          payer_id: params[:PayerID]
        }),
        amount: order.total,
        payment_method: payment_method
      })

      order.clone_shipping_address if order.bill_address == nil

      order.state = 'confirm'
      result = order.save

      logger.info ''
      logger.info 'Order has billing address: '
      logger.info order.bill_address.to_yaml
      logger.info 'Order saved: '
      logger.info result
      logger.info ''

      if order.complete?
        flash.notice = Spree.t(:order_processed_successfully)
        flash[:order_completed] = true
        session[:order_id] = nil
        redirect_to completion_route(order)
      else
        redirect_to checkout_state_path(order.state)
      end
    end



    # temporarily hard coded. need to be moved elsewhere
    def user_credentials
      {
        :VERSION => ENV['PP_VERSION'],
        :USER => ENV['PP_USER'],
        :PWD => ENV['PP_PWD'],
        :SIGNATURE => ENV['PP_SIGNATURE']
      }
    end

    def do_express_checkout_payment(pmt)
      payment_request_object = {
        :METHOD => 'DoExpressCheckoutPayment',
        :TOKEN => pmt.source.token,
        :PAYERID => pmt.source.payer_id,
        :PAYMENTACTION => 'Sale',
        :AMT => pmt.amount.to_f
      }

      request = payment_request_object.merge(user_credentials)

      logger.info request.to_yaml

      options = {
        body: request
      }

      pp_response = HTTParty.post("https://api-3t.paypal.com/nvp", options)
      response_object = Rack::Utils.parse_nested_query(pp_response.parsed_response)

      logger.info 'PP Response ACK: '+response_object['ACK']
      logger.info 'Message1: '+response_object['L_SHORTMESSAGE0']
      logger.info 'Message2: '+response_object['L_LONGMESSAGE0']
      logger.info ''

      response_object['ACK']

    end
    

    def cancel
      flash[:notice] = Spree.t('flash.cancel', scope: 'paypal')
      order = current_order || raise(ActiveRecord::RecordNotFound)
      redirect_to checkout_state_path(order.state, paypal_cancel_token: params[:token])
    end

    private

    def line_item(item)
      {
          Name: item.product.name,
          Number: item.variant.sku,
          Quantity: item.quantity,
          Amount: {
              currencyID: item.order.currency,
              value: item.price
          },
          ItemCategory: "Physical"
      }
    end

    def express_checkout_request_details order, items
      { SetExpressCheckoutRequestDetails: {
          InvoiceID: order.number,
          BuyerEmail: order.email,
          ReturnURL: confirm_paypal_url(payment_method_id: params[:payment_method_id], utm_nooverride: 1),
          CancelURL:  cancel_paypal_url,
          SolutionType: payment_method.preferred_solution.present? ? payment_method.preferred_solution : "Mark",
          LandingPage: payment_method.preferred_landing_page.present? ? payment_method.preferred_landing_page : "Billing",
          cppheaderimage: payment_method.preferred_logourl.present? ? payment_method.preferred_logourl : "",
          NoShipping: 1,
          PaymentDetails: [payment_details(items)]
      }}
    end

    def payment_method
      Spree::PaymentMethod.find(params[:payment_method_id])
    end

    def provider
      payment_method.provider
    end

    def payment_details items
      item_sum = items.sum { |i| i[:Quantity] * i[:Amount][:value] }

      adjusted_ship_total = current_order.ship_total.to_f - 4.95

      if current_order.adjustments.where({:source_id => 5, :eligible => true}).any?
        logger.info ''
        logger.info 'Free shipping promotion is eligible'
        logger.info ''
          shipment_sum = adjusted_ship_total
      else
        logger.info ''
        logger.info 'Free shipping promotion is NOT eligible'
        logger.info ''
          shipment_sum = current_order.ship_total
      end

      logger.info shipment_sum

      if item_sum.zero?
        # Paypal does not support no items or a zero dollar ItemTotal
        # This results in the order summary being simply "Current purchase"
        {
          :OrderTotal => {
            :currencyID => current_order.currency,
            :value => current_order.total
          }
        }
      else
        {
          :OrderTotal => {
            :currencyID => current_order.currency,
            :value => current_order.total
          },
          :ItemTotal => {
            :currencyID => current_order.currency,
            :value => item_sum
          },
          :ShippingTotal => {
            :currencyID => current_order.currency,
            :value => shipment_sum
          },
          :TaxTotal => {
            :currencyID => current_order.currency,
            :value => current_order.tax_total
          },
          :ShipToAddress => address_options,
          :PaymentDetailsItem => items,
          :ShippingMethod => "Shipping Method Name Goes Here",
          :PaymentAction => "Sale"
        }
      end
    end

    def address_options
      return {} unless address_required?

      {
          Name: current_order.bill_address.try(:full_name),
          Street1: current_order.bill_address.address1,
          Street2: current_order.bill_address.address2,
          CityName: current_order.bill_address.city,
          Phone: current_order.bill_address.phone,
          StateOrProvince: current_order.bill_address.state_text,
          Country: current_order.bill_address.country.iso,
          PostalCode: current_order.bill_address.zipcode
      }
    end

    def completion_route(order)
      order_path(order)
    end

    def address_required?
      payment_method.preferred_solution.eql?('Sole')
    end


  end
end
